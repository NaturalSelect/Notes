# Prometheus Plugin(Mgr Module) Module Source Code Analysis

[Source Code](https://github.com/ceph/ceph/blob/main/src/pybind/mgr/prometheus/module.py)

## Data Source

模块可以访问 mgr 维护的 Ceph 集群状态的内存副本。访问器功能作为 `MgrModule` 的成员公开。

访问集群或守护进程状态的调用通常从 Python 进入本机 C++ 例程。这会产生一些开销，但比调用 REST API 或调用 SQL 数据库等开销要少得多。

没有关于访问集群结构或守护程序元数据的一致性规则。例如，OSD 可能存在于 OSDMap 中但没有元数据，反之亦然。在健康的集群上，这些短暂状态非常罕见，但模块需要能应对这种可能性。

*NOTE： 即 mgr 与 mon 的数据不一致。*

mgr 守护进程从 mon 获取其大部分状态（例如集群映射）。如果 mon 集群不可访问，则无论哪个mgr 处于活动状态，都将继续运行，并且它看到的最新状态仍在内存中。

但是，如果您正在创建一个向用户显示集群状态的模块，那么您可能不想通过向他们显示过时的状态来误导他们。

## Working Principle

```python
def health_status_to_number(status: str) -> int:
    if status == 'HEALTH_OK':
        return 0
    elif status == 'HEALTH_WARN':
        return 1
    elif status == 'HEALTH_ERR':
        return 2
    raise ValueError(f'unknown status "{status}"')


DF_CLUSTER = ['total_bytes', 'total_used_bytes', 'total_used_raw_bytes']

DF_POOL = ['max_avail', 'avail_raw', 'stored', 'stored_raw', 'objects', 'dirty',
           'quota_bytes', 'quota_objects', 'rd', 'rd_bytes', 'wr', 'wr_bytes',
           'compress_bytes_used', 'compress_under_bytes', 'bytes_used', 'percent_used']

OSD_POOL_STATS = ('recovering_objects_per_sec', 'recovering_bytes_per_sec',
                  'recovering_keys_per_sec', 'num_objects_recovered',
                  'num_bytes_recovered', 'num_bytes_recovered')

OSD_FLAGS = ('noup', 'nodown', 'noout', 'noin', 'nobackfill', 'norebalance',
             'norecover', 'noscrub', 'nodeep-scrub')

FS_METADATA = ('data_pools', 'fs_id', 'metadata_pool', 'name')

MDS_METADATA = ('ceph_daemon', 'fs_id', 'hostname', 'public_addr', 'rank',
                'ceph_version')

MON_METADATA = ('ceph_daemon', 'hostname',
                'public_addr', 'rank', 'ceph_version')

MGR_METADATA = ('ceph_daemon', 'hostname', 'ceph_version')

MGR_STATUS = ('ceph_daemon',)

MGR_MODULE_STATUS = ('name',)

MGR_MODULE_CAN_RUN = ('name',)

OSD_METADATA = ('back_iface', 'ceph_daemon', 'cluster_addr', 'device_class',
                'front_iface', 'hostname', 'objectstore', 'public_addr',
                'ceph_version')

OSD_STATUS = ['weight', 'up', 'in']

OSD_STATS = ['apply_latency_ms', 'commit_latency_ms']

POOL_METADATA = ('pool_id', 'name', 'type', 'description', 'compression_mode')

RGW_METADATA = ('ceph_daemon', 'hostname', 'ceph_version', 'instance_id')

RBD_MIRROR_METADATA = ('ceph_daemon', 'id', 'instance_id', 'hostname',
                       'ceph_version')

DISK_OCCUPATION = ('ceph_daemon', 'device', 'db_device',
                   'wal_device', 'instance', 'devices', 'device_ids')

NUM_OBJECTS = ['degraded', 'misplaced', 'unfound']

alert_metric = namedtuple('alert_metric', 'name description')
HEALTH_CHECKS = [
    alert_metric('SLOW_OPS', 'OSD or Monitor requests taking a long time to process'),
]

HEALTHCHECK_DETAIL = ('name', 'severity')
```

插件使用一个单独的thread去搜集数据。

```python
class MetricCollectionThread(threading.Thread):
    def __init__(self, module: 'Module') -> None:
        self.mod = module
        self.active = True
        self.event = threading.Event()
        super(MetricCollectionThread, self).__init__(target=self.collect)

    def stop(self) -> None:
        self.active = False
        self.event.set()
```

他的`collect`函数是线程入口。

对于每一次循环：

* 查看当前线程是否退出（`self.active` flag）。
* 查看 mon 是否活跃（`self.mod.have_mon_connection`）：
    * 如果 mon 不活跃，输出错误日志并等待下一次循环。
    * 如果 mon 活跃，尝试收集数据，收集失败的处理与不活跃相同。

```python
    def collect(self) -> None:
        self.mod.log.info('starting metric collection thread')
        while self.active:
            self.mod.log.debug('collecting cache in thread')
            if self.mod.have_mon_connection():
                start_time = time.time()

                try:
                    data = self.mod.collect()
                except Exception:
                    # Log any issues encountered during the data collection and continue
                    self.mod.log.exception("failed to collect metrics:")
                    self.event.wait(self.mod.scrape_interval)
                    continue

                duration = time.time() - start_time
                self.mod.log.debug('collecting cache in thread done')

                sleep_time = self.mod.scrape_interval - duration
                if sleep_time < 0:
                    self.mod.log.warning(
                        'Collecting data took more time than configured scrape interval. '
                        'This possibly results in stale data. Please check the '
                        '`stale_cache_strategy` configuration option. '
                        'Collecting data took {:.2f} seconds but scrape interval is configured '
                        'to be {:.0f} seconds.'.format(
                            duration,
                            self.mod.scrape_interval,
                        )
                    )
                    sleep_time = 0

                with self.mod.collect_lock:
                    self.mod.collect_cache = data
                    self.mod.collect_time = duration

                self.event.wait(sleep_time)
            else:
                self.mod.log.error('No MON connection')
                self.event.wait(self.mod.scrape_interval)
```

### Collect Data

对于每一次收集过程：
* 先将之前收集到的数据清空。
* 收集各项指标。

```python
    @profile_method(True)
    def collect(self) -> str:
        # Clear the metrics before scraping
        for k in self.metrics.keys():
            self.metrics[k].clear()

        self.get_health()
        self.get_df()
        self.get_pool_stats()
        self.get_fs()
        self.get_osd_stats()
        self.get_quorum_status()
        self.get_mgr_status()
        self.get_metadata_and_osd_status()
        self.get_pg_status()
        self.get_num_objects()

        for daemon, counters in self.get_all_perf_counters().items():
            for path, counter_info in counters.items():
                # Skip histograms, they are represented by long running avgs
                stattype = self._stattype_to_str(counter_info['type'])
                if not stattype or stattype == 'histogram':
                    self.log.debug('ignoring %s, type %s' % (path, stattype))
                    continue

                path, label_names, labels = self._perfpath_to_path_labels(
                    daemon, path)

                # Get the value of the counter
                value = self._perfvalue_to_value(
                    counter_info['type'], counter_info['value'])

                # Represent the long running avgs as sum/count pairs
                if counter_info['type'] & self.PERFCOUNTER_LONGRUNAVG:
                    _path = path + '_sum'
                    if _path not in self.metrics:
                        self.metrics[_path] = Metric(
                            stattype,
                            _path,
                            counter_info['description'] + ' Total',
                            label_names,
                        )
                    self.metrics[_path].set(value, labels)

                    _path = path + '_count'
                    if _path not in self.metrics:
                        self.metrics[_path] = Metric(
                            'counter',
                            _path,
                            counter_info['description'] + ' Count',
                            label_names,
                        )
                    self.metrics[_path].set(counter_info['count'], labels,)
                else:
                    if path not in self.metrics:
                        self.metrics[path] = Metric(
                            stattype,
                            path,
                            counter_info['description'],
                            label_names,
                        )
                    self.metrics[path].set(value, labels)

        self.add_fixed_name_metrics()
        self.get_rbd_stats()

        self.get_collect_time_metrics()

        # Return formatted metrics and clear no longer used data
        _metrics = [m.str_expfmt() for m in self.metrics.values()]
        for k in self.metrics.keys():
            self.metrics[k].clear()

        return ''.join(_metrics) + '\n'
```

### Cluster Status

**以`get_health`为例。**

主要逻辑如下：
* 调用mgr的module interface（`self.get`）获得json object。
* 反序列化json object，从中提取数据填充`self.metrics`。

```python
    @profile_method()
    def get_health(self) -> None:

        def _get_value(message: str, delim: str = ' ', word_pos: int = 0) -> Tuple[int, int]:
            """Extract value from message (default is 1st field)"""
            v_str = message.split(delim)[word_pos]
            if v_str.isdigit():
                return int(v_str), 0
            return 0, 1

        health = json.loads(self.get('health')['json'])
        # set overall health
        self.metrics['health_status'].set(
            health_status_to_number(health['status'])
        )

        # Examine the health to see if any health checks triggered need to
        # become a specific metric with a value from the health detail
        active_healthchecks = health.get('checks', {})
        active_names = active_healthchecks.keys()

        for check in HEALTH_CHECKS:
            path = 'healthcheck_{}'.format(check.name.lower())

            if path in self.metrics:

                if check.name in active_names:
                    check_data = active_healthchecks[check.name]
                    message = check_data['summary'].get('message', '')
                    v, err = 0, 0

                    if check.name == "SLOW_OPS":
                        # 42 slow ops, oldest one blocked for 12 sec, daemons [osd.0, osd.3] have
                        # slow ops.
                        v, err = _get_value(message)

                    if err:
                        self.log.error(
                            "healthcheck %s message format is incompatible and has been dropped",
                            check.name)
                        # drop the metric, so it's no longer emitted
                        del self.metrics[path]
                        continue
                    else:
                        self.metrics[path].set(v)
                else:
                    # health check is not active, so give it a default of 0
                    self.metrics[path].set(0)

        self.health_history.check(health)
        for name, info in self.health_history.healthcheck.items():
            v = 1 if info.active else 0
            self.metrics['health_detail'].set(
                v, (
                    name,
                    str(info.severity))
            )

class MgrModule(ceph_module.BaseMgrModule, MgrModuleLoggingMixin):
    @API.expose
    def get(self, data_name: str) -> Any:
        """
        Called by the plugin to fetch named cluster-wide objects from ceph-mgr.

        :param str data_name: Valid things to fetch are osd_crush_map_text,
                osd_map, osd_map_tree, osd_map_crush, config, mon_map, fs_map,
                osd_metadata, pg_summary, io_rate, pg_dump, df, osd_stats,
                health, mon_status, devices, device <devid>, pg_stats,
                pool_stats, pg_ready, osd_ping_times.

        Note:
            All these structures have their own JSON representations: experiment
            or look at the C++ ``dump()`` methods to learn about them.
        """
        obj =  self._ceph_get(data_name)
        if isinstance(obj, bytes):
            obj = json.loads(obj)

        return obj
```

### Daemon Performance Counter

主要流程：
* 通过接口（`self.get_all_perf_counters()`）获得每一个daemon的perf_counters。
* 填充`self.metrics`。

```python
        for daemon, counters in self.get_all_perf_counters().items():
            for path, counter_info in counters.items():
                # Skip histograms, they are represented by long running avgs
                stattype = self._stattype_to_str(counter_info['type'])
                if not stattype or stattype == 'histogram':
                    self.log.debug('ignoring %s, type %s' % (path, stattype))
                    continue

                path, label_names, labels = self._perfpath_to_path_labels(
                    daemon, path)

                # Get the value of the counter
                value = self._perfvalue_to_value(
                    counter_info['type'], counter_info['value'])

                # Represent the long running avgs as sum/count pairs
                if counter_info['type'] & self.PERFCOUNTER_LONGRUNAVG:
                    _path = path + '_sum'
                    if _path not in self.metrics:
                        self.metrics[_path] = Metric(
                            stattype,
                            _path,
                            counter_info['description'] + ' Total',
                            label_names,
                        )
                    self.metrics[_path].set(value, labels)

                    _path = path + '_count'
                    if _path not in self.metrics:
                        self.metrics[_path] = Metric(
                            'counter',
                            _path,
                            counter_info['description'] + ' Count',
                            label_names,
                        )
                    self.metrics[_path].set(counter_info['count'], labels,)
                else:
                    if path not in self.metrics:
                        self.metrics[path] = Metric(
                            stattype,
                            path,
                            counter_info['description'],
                            label_names,
                        )
                    self.metrics[path].set(value, labels)
```