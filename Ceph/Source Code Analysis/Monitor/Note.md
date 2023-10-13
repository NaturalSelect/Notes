# Monitor Source Code Analysis

## Abstract

Monitor 是集群的Master，负责进行验证和集群管理。

基于Paxos构建，通过冗余实现高可用。

*NOTE：也支持非高可用的单点模式。*

## Bootstrap

一个Monitor有两个Messenger对象：
* `messenger` 成员。
* `mgr_messenger` 成员。


```cpp
int Monitor::init()
{
  dout(2) << "init" << dendl;
  std::lock_guard l(lock);

  finisher.start();

  // start ticker
  timer.init();
  new_tick();

  cpu_tp.start();

  // i'm ready!
  messenger->add_dispatcher_tail(this);

  // kickstart pet mgrclient
  mgr_client.init();
  mgr_messenger->add_dispatcher_tail(&mgr_client);
  mgr_messenger->add_dispatcher_tail(this);  // for auth ms_* calls
  mgrmon()->prime_mgr_client();

  state = STATE_PROBING;

  bootstrap();

  if (!elector.peer_tracker_is_clean()){
    dout(10) << "peer_tracker looks inconsistent"
      << " previous bad logic, clearing ..." << dendl;
    elector.notify_clear_peer_state();
  }

  // add features of myself into feature_map
  session_map.feature_map.add_mon(con_self->get_features());
  return 0;
}
```

```cpp
void Monitor::bootstrap()
{
  dout(10) << "bootstrap" << dendl;
  wait_for_paxos_write();

  sync_reset_requester();
  unregister_cluster_logger();
  cancel_probe_timeout();

  if (monmap->get_epoch() == 0) {
    dout(10) << "reverting to legacy ranks for seed monmap (epoch 0)" << dendl;
    monmap->calc_legacy_ranks();
  }
  dout(10) << "monmap " << *monmap << dendl;
  {
    auto from_release = monmap->min_mon_release;
    ostringstream err;
    if (!can_upgrade_from(from_release, "min_mon_release", err)) {
      derr << "current monmap has " << err.str() << " stopping." << dendl;
      exit(0);
    }
  }
  // note my rank
  int newrank = monmap->get_rank(messenger->get_myaddrs());
  if (newrank < 0 && rank >= 0) {
    // was i ever part of the quorum?
    if (has_ever_joined) {
      dout(0) << " removed from monmap, suicide." << dendl;
      exit(0);
    }
    elector.notify_clear_peer_state();
  }
  if (newrank >= 0 &&
      monmap->get_addrs(newrank) != messenger->get_myaddrs()) {
    dout(0) << " monmap addrs for rank " << newrank << " changed, i am "
	    << messenger->get_myaddrs()
	    << ", monmap is " << monmap->get_addrs(newrank) << ", respawning"
	    << dendl;

    if (monmap->get_epoch()) {
      // store this map in temp mon_sync location so that we use it on
      // our next startup
      derr << " stashing newest monmap " << monmap->get_epoch()
	   << " for next startup" << dendl;
      bufferlist bl;
      monmap->encode(bl, -1);
      auto t(std::make_shared<MonitorDBStore::Transaction>());
      t->put("mon_sync", "temp_newer_monmap", bl);
      store->apply_transaction(t);
    }

    respawn();
  }
  if (newrank != rank) {
    dout(0) << " my rank is now " << newrank << " (was " << rank << ")" << dendl;
    messenger->set_myname(entity_name_t::MON(newrank));
    rank = newrank;
    elector.notify_rank_changed(rank);

    // reset all connections, or else our peers will think we are someone else.
    messenger->mark_down_all();
  }

  // reset
  state = STATE_PROBING;

  _reset();

  // sync store
  if (g_conf()->mon_compact_on_bootstrap) {
    dout(10) << "bootstrap -- triggering compaction" << dendl;
    store->compact();
    dout(10) << "bootstrap -- finished compaction" << dendl;
  }

  // stretch mode bits
  set_elector_disallowed_leaders(false);

  // singleton monitor?
  if (monmap->size() == 1 && rank == 0) {
    win_standalone_election();
    return;
  }

  reset_probe_timeout();

  // i'm outside the quorum
  if (monmap->contains(name))
    outside_quorum.insert(name);

  // probe monitors
  dout(10) << "probing other monitors" << dendl;
  for (unsigned i = 0; i < monmap->size(); i++) {
    if ((int)i != rank)
      send_mon_message(
	new MMonProbe(monmap->fsid, MMonProbe::OP_PROBE, name, has_ever_joined,
		      ceph_release()),
	i);
  }
  for (auto& av : extra_probe_peers) {
    if (av != messenger->get_myaddrs()) {
      messenger->send_to_mon(
	new MMonProbe(monmap->fsid, MMonProbe::OP_PROBE, name, has_ever_joined,
		      ceph_release()),
	av);
    }
  }
}
```

```cpp
void Monitor::reset_probe_timeout()
{
  cancel_probe_timeout();
  probe_timeout_event = new C_MonContext{this, [this](int r) {
      probe_timeout(r);
    }};
  double t = g_conf()->mon_probe_timeout;
  if (timer.add_event_after(t, probe_timeout_event)) {
    dout(10) << "reset_probe_timeout " << probe_timeout_event
	     << " after " << t << " seconds" << dendl;
  } else {
    probe_timeout_event = nullptr;
  }
}

void Monitor::probe_timeout(int r)
{
  dout(4) << "probe_timeout " << probe_timeout_event << dendl;
  ceph_assert(is_probing() || is_synchronizing());
  ceph_assert(probe_timeout_event);
  probe_timeout_event = NULL;
  bootstrap();
}
```

## Dispatch & Handle Request

```cpp
void Monitor::dispatch_op(MonOpRequestRef op)
{
  op->mark_event("mon:dispatch_op");
  MonSession *s = op->get_session();
  ceph_assert(s);
  if (s->closed) {
    dout(10) << " session closed, dropping " << op->get_req() << dendl;
    return;
  }

  /* we will consider the default type as being 'monitor' until proven wrong */
  op->set_type_monitor();
  /* deal with all messages that do not necessarily need caps */
  switch (op->get_req()->get_type()) {
    // auth
    case MSG_MON_GLOBAL_ID:
    case MSG_MON_USED_PENDING_KEYS:
    case CEPH_MSG_AUTH:
      op->set_type_service();
      /* no need to check caps here */
      paxos_service[PAXOS_AUTH]->dispatch(op);
      return;

    case CEPH_MSG_PING:
      handle_ping(op);
      return;
    case MSG_COMMAND:
      op->set_type_command();
      handle_tell_command(op);
      return;
  }

  if (!op->get_session()->authenticated) {
    dout(5) << __func__ << " " << op->get_req()->get_source_inst()
            << " is not authenticated, dropping " << *(op->get_req())
            << dendl;
    return;
  }

  // global_id_status == NONE: all sessions for auth_none and krb,
  // mon <-> mon sessions (including proxied sessions) for cephx
  ceph_assert(s->global_id_status == global_id_status_t::NONE ||
              s->global_id_status == global_id_status_t::NEW_OK ||
              s->global_id_status == global_id_status_t::NEW_NOT_EXPOSED ||
              s->global_id_status == global_id_status_t::RECLAIM_OK ||
              s->global_id_status == global_id_status_t::RECLAIM_INSECURE);

  // let mon_getmap through for "ping" (which doesn't reconnect)
  // and "tell" (which reconnects but doesn't attempt to preserve
  // its global_id and stays in NEW_NOT_EXPOSED, retrying until
  // ->send_attempts reaches 0)
  if (cct->_conf->auth_expose_insecure_global_id_reclaim &&
      s->global_id_status == global_id_status_t::NEW_NOT_EXPOSED &&
      op->get_req()->get_type() != CEPH_MSG_MON_GET_MAP) {
    dout(5) << __func__ << " " << op->get_req()->get_source_inst()
            << " may omit old_ticket on reconnects, discarding "
            << *op->get_req() << " and forcing reconnect" << dendl;
    ceph_assert(s->con && !s->proxy_con);
    s->con->mark_down();
    {
      std::lock_guard l(session_map_lock);
      remove_session(s);
    }
    op->mark_zap();
    return;
  }

  switch (op->get_req()->get_type()) {
    case CEPH_MSG_MON_GET_MAP:
      handle_mon_get_map(op);
      return;

    case MSG_GET_CONFIG:
      configmon()->handle_get_config(op);
      return;

    case CEPH_MSG_MON_SUBSCRIBE:
      /* FIXME: check what's being subscribed, filter accordingly */
      handle_subscribe(op);
      return;
  }

  /* well, maybe the op belongs to a service... */
  op->set_type_service();
  /* deal with all messages which caps should be checked somewhere else */
  switch (op->get_req()->get_type()) {

    // OSDs
    case CEPH_MSG_MON_GET_OSDMAP:
    case CEPH_MSG_POOLOP:
    case MSG_OSD_BEACON:
    case MSG_OSD_MARK_ME_DOWN:
    case MSG_OSD_MARK_ME_DEAD:
    case MSG_OSD_FULL:
    case MSG_OSD_FAILURE:
    case MSG_OSD_BOOT:
    case MSG_OSD_ALIVE:
    case MSG_OSD_PGTEMP:
    case MSG_OSD_PG_CREATED:
    case MSG_REMOVE_SNAPS:
    case MSG_MON_GET_PURGED_SNAPS:
    case MSG_OSD_PG_READY_TO_MERGE:
      paxos_service[PAXOS_OSDMAP]->dispatch(op);
      return;

    // MDSs
    case MSG_MDS_BEACON:
    case MSG_MDS_OFFLOAD_TARGETS:
      paxos_service[PAXOS_MDSMAP]->dispatch(op);
      return;

    // Mgrs
    case MSG_MGR_BEACON:
      paxos_service[PAXOS_MGR]->dispatch(op);
      return;

    // MgrStat
    case MSG_MON_MGR_REPORT:
    case CEPH_MSG_STATFS:
    case MSG_GETPOOLSTATS:
      paxos_service[PAXOS_MGRSTAT]->dispatch(op);
      return;

      // log
    case MSG_LOG:
      paxos_service[PAXOS_LOG]->dispatch(op);
      return;

    // handle_command() does its own caps checking
    case MSG_MON_COMMAND:
      op->set_type_command();
      handle_command(op);
      return;
  }

  /* nop, looks like it's not a service message; revert back to monitor */
  op->set_type_monitor();

  /* messages we, the Monitor class, need to deal with
   * but may be sent by clients. */

  if (!op->get_session()->is_capable("mon", MON_CAP_R)) {
    dout(5) << __func__ << " " << op->get_req()->get_source_inst()
            << " not enough caps for " << *(op->get_req()) << " -- dropping"
            << dendl;
    return;
  }

  switch (op->get_req()->get_type()) {
    // misc
    case CEPH_MSG_MON_GET_VERSION:
      handle_get_version(op);
      return;
  }

  if (!op->is_src_mon()) {
    dout(1) << __func__ << " unexpected monitor message from"
            << " non-monitor entity " << op->get_req()->get_source_inst()
            << " " << *(op->get_req()) << " -- dropping" << dendl;
    return;
  }

  /* messages that should only be sent by another monitor */
  switch (op->get_req()->get_type()) {

    case MSG_ROUTE:
      handle_route(op);
      return;

    case MSG_MON_PROBE:
      handle_probe(op);
      return;

    // Sync (i.e., the new slurp, but on steroids)
    case MSG_MON_SYNC:
      handle_sync(op);
      return;
    case MSG_MON_SCRUB:
      handle_scrub(op);
      return;

    /* log acks are sent from a monitor we sent the MLog to, and are
       never sent by clients to us. */
    case MSG_LOGACK:
      log_client.handle_log_ack((MLogAck*)op->get_req());
      return;

    // monmap
    case MSG_MON_JOIN:
      op->set_type_service();
      paxos_service[PAXOS_MONMAP]->dispatch(op);
      return;

    // paxos
    case MSG_MON_PAXOS:
      {
        op->set_type_paxos();
        auto pm = op->get_req<MMonPaxos>();
        if (!op->get_session()->is_capable("mon", MON_CAP_X)) {
          //can't send these!
          return;
        }

        if (state == STATE_SYNCHRONIZING) {
          // we are synchronizing. These messages would do us no
          // good, thus just drop them and ignore them.
          dout(10) << __func__ << " ignore paxos msg from "
            << pm->get_source_inst() << dendl;
          return;
        }

        // sanitize
        if (pm->epoch > get_epoch()) {
          bootstrap();
          return;
        }
        if (pm->epoch != get_epoch()) {
          return;
        }

        paxos->dispatch(op);
      }
      return;

    // elector messages
    case MSG_MON_ELECTION:
      op->set_type_election_or_ping();
      //check privileges here for simplicity
      if (!op->get_session()->is_capable("mon", MON_CAP_X)) {
        dout(0) << "MMonElection received from entity without enough caps!"
          << op->get_session()->caps << dendl;
        return;;
      }
      if (!is_probing() && !is_synchronizing()) {
        elector.dispatch(op);
      }
      return;

    case MSG_MON_PING:
      op->set_type_election_or_ping();
      elector.dispatch(op);
      return;

    case MSG_FORWARD:
      handle_forward(op);
      return;

    case MSG_TIMECHECK:
      dout(5) << __func__ << " ignoring " << op << dendl;
      return;
    case MSG_TIMECHECK2:
      handle_timecheck(op);
      return;

    case MSG_MON_HEALTH:
      dout(5) << __func__ << " dropping deprecated message: "
	      << *op->get_req() << dendl;
      break;
    case MSG_MON_HEALTH_CHECKS:
      op->set_type_service();
      paxos_service[PAXOS_HEALTH]->dispatch(op);
      return;
  }
  dout(1) << "dropping unexpected " << *(op->get_req()) << dendl;
  return;
}
```

## Paxos Service

主体业务逻辑在`paxos_service`成员中。

```cpp
std::array<std::unique_ptr<PaxosService>, PAXOS_NUM> paxos_service;
```

```cpp
bool PaxosService::dispatch(MonOpRequestRef op)
{
  ceph_assert(op->is_type_service() || op->is_type_command());
  auto m = op->get_req<PaxosServiceMessage>();
  op->mark_event("psvc:dispatch");

  dout(10) << __func__ << " " << m << " " << *m
	   << " from " << m->get_orig_source_inst()
	   << " con " << m->get_connection() << dendl;

  if (mon.is_shutdown()) {
    return true;
  }

  // make sure this message isn't forwarded from a previous election epoch
  if (m->rx_election_epoch &&
      m->rx_election_epoch < mon.get_epoch()) {
    dout(10) << " discarding forwarded message from previous election epoch "
	     << m->rx_election_epoch << " < " << mon.get_epoch() << dendl;
    return true;
  }

  // make sure the client is still connected.  note that a proxied
  // connection will be disconnected with a null message; don't drop
  // those.  also ignore loopback (e.g., log) messages.
  if (m->get_connection() &&
      !m->get_connection()->is_connected() &&
      m->get_connection() != mon.con_self &&
      m->get_connection()->get_messenger() != NULL) {
    dout(10) << " discarding message from disconnected client "
	     << m->get_source_inst() << " " << *m << dendl;
    return true;
  }

  // make sure our map is readable and up to date
  if (!is_readable(m->version)) {
    dout(10) << " waiting for paxos -> readable (v" << m->version << ")" << dendl;
    wait_for_readable(op, new C_RetryMessage(this, op), m->version);
    return true;
  }

  // preprocess
  if (preprocess_query(op))
    return true;  // easy!

  // leader?
  if (!mon.is_leader()) {
    mon.forward_request_leader(op);
    return true;
  }

  // writeable?
  if (!is_writeable()) {
    dout(10) << " waiting for paxos -> writeable" << dendl;
    wait_for_writeable(op, new C_RetryMessage(this, op));
    return true;
  }

  // update
  if (!prepare_update(op)) {
    // no changes made.
    return true;
  }

  if (need_immediate_propose) {
    dout(10) << __func__ << " forced immediate propose" << dendl;
    propose_pending();
    return true;
  }

  double delay = 0.0;
  if (!should_propose(delay)) {
    dout(10) << " not proposing" << dendl;
    return true;
  }

  if (delay == 0.0) {
    propose_pending();
    return true;
  }

  // delay a bit
  if (!proposal_timer) {
    /**
       * Callback class used to propose the pending value once the proposal_timer
       * fires up.
       */
    auto do_propose = new C_MonContext{&mon, [this](int r) {
        proposal_timer = 0;
        if (r >= 0) {
          propose_pending();
        } else if (r == -ECANCELED || r == -EAGAIN) {
          return;
        } else {
          ceph_abort_msg("bad return value for proposal_timer");
        }
    }};
    dout(10) << " setting proposal_timer " << do_propose
             << " with delay of " << delay << dendl;
    proposal_timer = mon.timer.add_event_after(delay, do_propose);
  } else {
    dout(10) << " proposal_timer already set" << dendl;
  }
  return true;
}
```

```cpp
void PaxosService::propose_pending()
{
  dout(10) << __func__ << dendl;
  ceph_assert(have_pending);
  ceph_assert(!proposing);
  ceph_assert(mon.is_leader());
  ceph_assert(is_active());

  if (proposal_timer) {
    dout(10) << " canceling proposal_timer " << proposal_timer << dendl;
    mon.timer.cancel_event(proposal_timer);
    proposal_timer = NULL;
  }

  /**
   * @note What we contribute to the pending Paxos transaction is
   *	   obtained by calling a function that must be implemented by
   *	   the class implementing us.  I.e., the function
   *	   encode_pending will be the one responsible to encode
   *	   whatever is pending on the implementation class into a
   *	   bufferlist, so we can then propose that as a value through
   *	   Paxos.
   */
  MonitorDBStore::TransactionRef t = paxos.get_pending_transaction();

  if (should_stash_full())
    encode_full(t);

  encode_pending(t);
  have_pending = false;

  if (format_version > 0) {
    t->put(get_service_name(), "format_version", format_version);
  }

  // apply to paxos
  proposing = true;
  need_immediate_propose = false; /* reset whenever we propose */
  /**
   * Callback class used to mark us as active once a proposal finishes going
   * through Paxos.
   *
   * We should wake people up *only* *after* we inform the service we
   * just went active. And we should wake people up only once we finish
   * going active. This is why we first go active, avoiding to wake up the
   * wrong people at the wrong time, such as waking up a C_RetryMessage
   * before waking up a C_Active, thus ending up without a pending value.
   */
  class C_Committed : public Context {
    PaxosService *ps;
  public:
    explicit C_Committed(PaxosService *p) : ps(p) { }
    void finish(int r) override {
      ps->proposing = false;
      if (r >= 0)
	        ps->_active();
      else if (r == -ECANCELED || r == -EAGAIN)
	        return;
      else
	        ceph_abort_msg("bad return value for C_Committed");
    }
  };
  paxos.queue_pending_finisher(new C_Committed(this));
  paxos.trigger_propose();
}
```

```cpp
void PaxosService::_active()
{
  if (is_proposing()) {
    dout(10) << __func__ << " - proposing" << dendl;
    return;
  }
  if (!is_active()) {
    dout(10) << __func__ << " - not active" << dendl;
    /**
     * Callback used to make sure we call the PaxosService::_active function
     * whenever a condition is fulfilled.
     *
     * This is used in multiple situations, from waiting for the Paxos to commit
     * our proposed value, to waiting for the Paxos to become active once an
     * election is finished.
     */
    class C_Active : public Context {
      PaxosService *svc;
    public:
      explicit C_Active(PaxosService *s) : svc(s) {}
      void finish(int r) override {
	if (r >= 0)
	  svc->_active();
      }
    };
    wait_for_active_ctx(new C_Active(this));
    return;
  }
  dout(10) << __func__ << dendl;

  // create pending state?
  if (mon.is_leader()) {
    dout(7) << __func__ << " creating new pending" << dendl;
    if (!have_pending) {
      create_pending();
      have_pending = true;
    }

    if (get_last_committed() == 0) {
      // create initial state
      create_initial();
      propose_pending();
      return;
    }
  } else {
    dout(7) << __func__ << " we are not the leader, hence we propose nothing!" << dendl;
  }

  // wake up anyone who came in while we were proposing.  note that
  // anyone waiting for the previous proposal to commit is no longer
  // on this list; it is on Paxos's.
  finish_contexts(g_ceph_context, waiting_for_finished_proposal, 0);

  if (mon.is_leader())
    upgrade_format();

  // NOTE: it's possible that this will get called twice if we commit
  // an old paxos value.  Implementations should be mindful of that.
  on_active();
}
```

接口的实现主要关注`preprocess_query`、`prepare_update`和`encode_pending`。

* `preprocess_query` 决定是否需要改变状态，如果只读就能走快路径。
* `prepare_update` 决定是否提交Paxos事务（实际业务逻辑）。
* `encode_pending` 决定服务如何填充事务数据。

```cpp
/**
   * Look at the query; if the query can be handled without changing state,
   * do so.
   *
   * @param m A query message
   * @returns 'true' if the query was handled (e.g., was a read that got
   *	      answered, was a state change that has no effect); 'false'
   *	      otherwise.
   */
  virtual bool preprocess_query(MonOpRequestRef op) = 0;

  /**
   * Apply the message to the pending state.
   *
   * @invariant This function is only called on a Leader.
   *
   * @param m An update message
   * @returns 'true' if the pending state should be proposed; 'false' otherwise.
   */
  virtual bool prepare_update(MonOpRequestRef op) = 0;

  virtual void encode_pending(MonitorDBStore::TransactionRef t) = 0;
```

```cpp
void MDSMonitor::encode_pending(MonitorDBStore::TransactionRef t)
{
  auto &pending = get_pending_fsmap_writeable();
  auto epoch = pending.get_epoch();

  dout(10) << "encode_pending e" << epoch << dendl;

  // print map iff 'debug mon = 30' or higher
  print_map<30>(pending);
  if (!g_conf()->mon_mds_skip_sanity) {
    pending.sanity(true);
  }

  // apply to paxos
  ceph_assert(get_last_committed() + 1 == pending.get_epoch());
  bufferlist pending_bl;
  pending.encode(pending_bl, mon.get_quorum_con_features());

  /* put everything in the transaction */
  put_version(t, pending.get_epoch(), pending_bl);
  put_last_committed(t, pending.get_epoch());

  // Encode MDSHealth data
  for (map<uint64_t, MDSHealth>::iterator i = pending_daemon_health.begin();
      i != pending_daemon_health.end(); ++i) {
    bufferlist bl;
    i->second.encode(bl);
    t->put(MDS_HEALTH_PREFIX, stringify(i->first), bl);
  }

  for (set<uint64_t>::iterator i = pending_daemon_health_rm.begin();
      i != pending_daemon_health_rm.end(); ++i) {
    t->erase(MDS_HEALTH_PREFIX, stringify(*i));
  }
  pending_daemon_health_rm.clear();
  remove_from_metadata(pending, t);

  // health
  health_check_map_t new_checks;
  const auto &info_map = pending.get_mds_info();
  for (const auto &i : info_map) {
    const auto &gid = i.first;
    const auto &info = i.second;
    if (pending_daemon_health_rm.count(gid)) {
      continue;
    }
    MDSHealth health;
    auto p = pending_daemon_health.find(gid);
    if (p != pending_daemon_health.end()) {
      health = p->second;
    } else {
      bufferlist bl;
      mon.store->get(MDS_HEALTH_PREFIX, stringify(gid), bl);
      if (!bl.length()) {
	derr << "Missing health data for MDS " << gid << dendl;
	continue;
      }
      auto bl_i = bl.cbegin();
      health.decode(bl_i);
    }
    for (const auto &metric : health.metrics) {
      if (metric.type == MDS_HEALTH_DUMMY) {
        continue;
      }
      const auto rank = info.rank;
      health_check_t *check = &new_checks.get_or_add(
	mds_metric_name(metric.type),
	metric.sev,
	mds_metric_summary(metric.type),
	1);
      ostringstream ss;
      ss << "mds." << info.name << "(mds." << rank << "): " << metric.message;
      bool first = true;
      for (auto &p : metric.metadata) {
	if (first) {
	  ss << " ";
	} else {
	  ss << ", ";
        }
	ss << p.first << ": " << p.second;
        first = false;
      }
      check->detail.push_back(ss.str());
    }
  }
  pending.get_health_checks(&new_checks);
  for (auto& p : new_checks.checks) {
    p.second.summary = std::regex_replace(
      p.second.summary,
      std::regex("%num%"),
      stringify(p.second.detail.size()));
    p.second.summary = std::regex_replace(
      p.second.summary,
      std::regex("%plurals%"),
      p.second.detail.size() > 1 ? "s" : "");
    p.second.summary = std::regex_replace(
      p.second.summary,
      std::regex("%isorare%"),
      p.second.detail.size() > 1 ? "are" : "is");
    p.second.summary = std::regex_replace(
      p.second.summary,
      std::regex("%hasorhave%"),
      p.second.detail.size() > 1 ? "have" : "has");
  }
  encode_health(new_checks, t);
}
```

```cpp
bool MDSMonitor::prepare_command(MonOpRequestRef op)
{
  op->mark_mdsmon_event(__func__);
  auto m = op->get_req<MMonCommand>();
  int r = -EINVAL;
  stringstream ss;
  bufferlist rdata;

  cmdmap_t cmdmap;
  if (!cmdmap_from_json(m->cmd, &cmdmap, ss)) {
    string rs = ss.str();
    mon.reply_command(op, -EINVAL, rs, rdata, get_last_committed());
    return false;
  }

  string prefix;
  cmd_getval(cmdmap, "prefix", prefix);

  /* Refuse access if message not associated with a valid session */
  MonSession *session = op->get_session();
  if (!session) {
    mon.reply_command(op, -EACCES, "access denied", rdata, get_last_committed());
    return false;
  }

  auto &pending = get_pending_fsmap_writeable();

  for (const auto &h : handlers) {
    r = h->can_handle(prefix, op, pending, cmdmap, ss);
    if (r == 1) {
      ; // pass, since we got the right handler.
    } else if (r == 0) {
      continue;
    } else {
      goto out;
    }

    r = h->handle(&mon, pending, op, cmdmap, ss);

    if (r == -EAGAIN) {
      // message has been enqueued for retry; return.
      dout(4) << __func__ << " enqueue for retry by prepare_command" << dendl;
      return false;
    } else {
      if (r == 0) {
	// On successful updates, print the updated map
	print_map(pending);
      }
      // Successful or not, we're done: respond.
      goto out;
    }
  }

  r = filesystem_command(pending, op, prefix, cmdmap, ss);
  if (r >= 0) {
    goto out;
  } else if (r == -EAGAIN) {
    // Do not reply, the message has been enqueued for retry
    dout(4) << __func__ << " enqueue for retry by filesystem_command" << dendl;
    return false;
  } else if (r != -ENOSYS) {
    goto out;
  }

  if (r == -ENOSYS && ss.str().empty()) {
    ss << "unrecognized command";
  }

out:
  dout(4) << __func__ << " done, r=" << r << dendl;
  /* Compose response */
  string rs = ss.str();

  if (r >= 0) {
    // success.. delay reply
    wait_for_commit(op, new Monitor::C_Command(mon, op, r, rs,
					      get_last_committed() + 1));
    return true;
  } else {
    // reply immediately
    mon.reply_command(op, r, rs, rdata, get_last_committed());
    return false;
  }
}

int MDSMonitor::filesystem_command(
    FSMap &fsmap,
    MonOpRequestRef op,
    string const &prefix,
    const cmdmap_t& cmdmap,
    stringstream &ss)
{
  dout(4) << __func__ << " prefix='" << prefix << "'" << dendl;
  op->mark_mdsmon_event(__func__);
  int r = 0;
  string whostr;
  cmd_getval(cmdmap, "role", whostr);

  if (prefix == "mds set_state") {
    mds_gid_t gid;
    if (!cmd_getval(cmdmap, "gid", gid)) {
      ss << "error parsing 'gid' value '"
         << cmd_vartype_stringify(cmdmap.at("gid")) << "'";
      return -EINVAL;
    }
    MDSMap::DaemonState state;
    if (!cmd_getval(cmdmap, "state", state)) {
      ss << "error parsing 'state' string value '"
         << cmd_vartype_stringify(cmdmap.at("state")) << "'";
      return -EINVAL;
    }
    if (fsmap.gid_exists(gid, op->get_session()->get_allowed_fs_names())) {
      fsmap.modify_daemon(gid, [state](auto& info) {
        info.state = state;
      });
      ss << "set mds gid " << gid << " to state " << state << " "
         << ceph_mds_state_name(state);
      return 0;
    }
  } else if (prefix == "mds fail") {
    string who;
    cmd_getval(cmdmap, "role_or_gid", who);

    MDSMap::mds_info_t failed_info;
    mds_gid_t gid = gid_from_arg(fsmap, who, ss);
    if (gid == MDS_GID_NONE) {
      ss << "MDS named '" << who << "' does not exist, is not up or you "
	 << "lack the permission to see.";
      return 0;
    }
    if(!fsmap.gid_exists(gid, op->get_session()->get_allowed_fs_names())) {
      ss << "MDS named '" << who << "' does not exist, is not up or you "
	 << "lack the permission to see.";
      return -EINVAL;
    }
    string_view fs_name = fsmap.fs_name_from_gid(gid);
    if (!op->get_session()->fs_name_capable(fs_name, MON_CAP_W)) {
      ss << "Permission denied.";
      return -EPERM;
    }

    r = fail_mds(fsmap, ss, who, &failed_info);
    if (r < 0 && r == -EAGAIN) {
      mon.osdmon()->wait_for_writeable(op, new C_RetryMessage(this, op));
      return -EAGAIN; // don't propose yet; wait for message to be retried
    } else if (r == 0) {
      // Only log if we really did something (not when was already gone)
      if (failed_info.global_id != MDS_GID_NONE) {
        mon.clog->info() << failed_info.human_name() << " marked failed by "
                          << op->get_session()->entity_name;
      }
    }
  } else if (prefix == "mds rm") {
    mds_gid_t gid;
    if (!cmd_getval(cmdmap, "gid", gid)) {
      ss << "error parsing 'gid' value '"
         << cmd_vartype_stringify(cmdmap.at("gid")) << "'";
      return -EINVAL;
    }
    if (!fsmap.gid_exists(gid, op->get_session()->get_allowed_fs_names())) {
      ss << "mds gid " << gid << " does not exist";
      return 0;
    }
    string_view fs_name = fsmap.fs_name_from_gid(gid);
    if (!op->get_session()->fs_name_capable(fs_name, MON_CAP_W)) {
      ss << "Permission denied.";
      return -EPERM;
    }
    const auto &info = fsmap.get_info_gid(gid);
    MDSMap::DaemonState state = info.state;
    if (state > 0) {
    ss << "cannot remove active mds." << info.name
	<< " rank " << info.rank;
    return -EBUSY;
    } else {
    fsmap.erase(gid, {});
    ss << "removed mds gid " << gid;
    return 0;
    }
  } else if (prefix == "mds rmfailed") {
    bool confirm = false;
    cmd_getval(cmdmap, "yes_i_really_mean_it", confirm);
    if (!confirm) {
         ss << "WARNING: this can make your filesystem inaccessible! "
               "Add --yes-i-really-mean-it if you are sure you wish to continue.";
         return -EPERM;
    }

    string role_str;
    cmd_getval(cmdmap, "role", role_str);
    mds_role_t role;
    const auto fs_names = op->get_session()->get_allowed_fs_names();
    int r = fsmap.parse_role(role_str, &role, ss, fs_names);
    if (r < 0) {
      ss << "invalid role '" << role_str << "'";
      return -EINVAL;
    }
    string_view fs_name = fsmap.get_filesystem(role.fscid).get_mds_map().get_fs_name();
    if (!op->get_session()->fs_name_capable(fs_name, MON_CAP_W)) {
      ss << "Permission denied.";
      return -EPERM;
    }

    fsmap.modify_filesystem(
        role.fscid,
        [role](auto&& fs)
    {
      fs.get_mds_map().failed.erase(role.rank);
    });

    ss << "removed failed mds." << role;
    return 0;
    /* TODO: convert to fs commands to update defaults */
  } else if (prefix == "mds compat rm_compat") {
    int64_t f;
    if (!cmd_getval(cmdmap, "feature", f)) {
      ss << "error parsing feature value '"
         << cmd_vartype_stringify(cmdmap.at("feature")) << "'";
      return -EINVAL;
    }
    auto& default_compat = fsmap.get_default_compat();
    if (default_compat.compat.contains(f)) {
      ss << "removing compat feature " << f;
      default_compat.compat.remove(f);
    } else {
      ss << "compat feature " << f << " not present in " << default_compat;
    }
    r = 0;
  } else if (prefix == "mds compat rm_incompat") {
    int64_t f;
    if (!cmd_getval(cmdmap, "feature", f)) {
      ss << "error parsing feature value '"
         << cmd_vartype_stringify(cmdmap.at("feature")) << "'";
      return -EINVAL;
    }
    auto& default_compat = fsmap.get_default_compat();
    if (default_compat.incompat.contains(f)) {
      ss << "removing incompat feature " << f;
      default_compat.incompat.remove(f);
    } else {
      ss << "incompat feature " << f << " not present in " << default_compat;
    }
    r = 0;
  } else if (prefix == "mds repaired") {
    string role_str;
    cmd_getval(cmdmap, "role", role_str);
    mds_role_t role;
    const auto fs_names = op->get_session()->get_allowed_fs_names();
    r = fsmap.parse_role(role_str, &role, ss, fs_names);
    if (r < 0) {
      return r;
    }
    string_view fs_name = fsmap.get_filesystem(role.fscid).get_mds_map().get_fs_name();
    if (!op->get_session()->fs_name_capable(fs_name, MON_CAP_W)) {
      ss << "Permission denied.";
      return -EPERM;
    }

    bool modified = fsmap.undamaged(role.fscid, role.rank);
    if (modified) {
      ss << "repaired: restoring rank " << role;
    } else {
      ss << "nothing to do: rank is not damaged";
    }

    r = 0;
  } else if (prefix == "mds freeze") {
    string who;
    cmd_getval(cmdmap, "role_or_gid", who);
    mds_gid_t gid = gid_from_arg(fsmap, who, ss);
    if (gid == MDS_GID_NONE) {
      return -EINVAL;
    }

    string_view fs_name = fsmap.fs_name_from_gid(gid);
    if (!op->get_session()->fs_name_capable(fs_name, MON_CAP_W)) {
      ss << "Permission denied.";
      return -EPERM;
    }

    bool freeze = false;
    {
      string str;
      cmd_getval(cmdmap, "val", str);
      if ((r = parse_bool(str, &freeze, ss)) != 0) {
        return r;
      }
    }

    auto f = [freeze,gid,&ss](auto& info) {
      if (freeze) {
        ss << "freezing mds." << gid;
        info.freeze();
      } else {
        ss << "unfreezing mds." << gid;
        info.unfreeze();
      }
    };
    fsmap.modify_daemon(gid, f);
    r = 0;
  } else {
    return -ENOSYS;
  }

  return r;
}
```

## CRUSH



## Placement Group

## Pool

