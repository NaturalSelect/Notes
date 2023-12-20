# Copyset Migration

本文记录我关于Copyset热迁移的一些想法。

首先解释一些名词：
* Master - Master集群，负责指定Partition的Copyset。
* Copyset - 副本集，组成分区（Partition）的节点的集合。
* Membership - Copyset的成员资格。
* Hot Migration - 指当Copyset改变甚至完全改变时，不停止服务。
* Append Only System - 仅追加系统。
* Raft Based System - 基于Raft的系统。
* Backfill - 回填，见下文。
* Acting Size - Acting Set的大小。

本文的很多想法受到RADOS的启发，因此设计与RADOS类似。

为了进行热迁移，我们需要把Copyset的Membership分成三个部分：
* Stray Set - 当前有完整数据的节点集合。
* Acting Set - 当前正在提供服务的节点集合。
* Up Set - Master指定的最新Copyset。

在未进行迁移时，这三者的内容相同。

下面对不同的系统进行分类讨论。

## Append Only System

仅追加系统的基本存储对象是Extent，每个Extent可以进行如下操作：
* Append - 最加新数据到Extent的末尾。
* Purge - 打洞，回收Extent在`[begin,end)`处的空间，读取被打洞的Range将返回Purge标识或全0值。
* Delete - 删除Extent。

仅追加系统起源于GFS，后来被WAS广泛使用。

在仅追加系统中，每一个Partition存储一定数据的Extent，这些Extent有唯一的递增id。

同时Extent存在最大大小的限制，也存在一些特殊的Extent：
* DeleteExtent（`0`） - 负责记录被删除的Extent id，该Extent不能被purge或delete且没有最大大小限制。
* PurgeExtent（`1`） - 负责记录Purge的Extent id和对应的Range，该Extent不能被purge或delete且没有最大大小限制。

仅追加系统是强一致的（使用Primary-back Replication），只有Primary提供服务，一旦Primary宕掉，则分区只读（Acting Set里面掉任何一个节点都会导致只读）。

同时维护一个总大小，该大小只增加。

### Recovery

此类型系统的恢复流程，较为简单，因为Extent是仅追加的。

恢复分为两个部分：
* 针对整个分区数据的Backfill（回填）。
* 针对单个Extent的Single Extent Recovery。

每一轮的恢复（回填）流程如下：
* 首先需要从Primary按id顺序读取所有的extent。
* 第一个被恢复的Extent是DeleteExtent，这个Extent记录了所有被删除的Extent，同时它本身必然保持比较小的大小（一个id只有4字节）并replay删除操作。
* 接着读取PurgeExtent（这个Extent不可能被删除），它同样也保持比较小的大小（一条记录只有12（4+4+4）字节）。
* 然后读取其他Extent，跳过被删除的Extent，如果当前节点的Extent比Primary长，则截断到Primary的大小。
* 最后replay purge操作。

### Write Flow & Single Extent Recovery

当需要往一个Extent里面写入数据时，Primary首先在自己的Extent上面写入，然后发送写入（附带Primary写入之前的Extent size）到所有的Replicas。

当Replicas发现写入包的Extent size与自己的大小一致时，接受写入，否则拒绝。

当Primary发现所有的Replicas都完成写入时，更新自己和Replicas的Extent大小。

如果Replicas拒绝写入，则Primary对这个Replica进行Single Extent Recovery：
* 将Replica的Extent恢复到与自己的先前大小相同，如果当前节点的Extent比Primary长，则截断到Primary的大小。
* 然后恢复Replicas的DeleteExtent和PurgeExtent。

因此Primary必须得知所有Replicas的所有Extent的大小，在启动时，其会进行一轮Backfill，成功之后将Replicas的所有Extent大小设置为与Primary相同。

### Migration

以上的情况都针对没迁移的场景，下面把它扩展到有迁移的场景，同时需要引入一个叫Peering的过程。

Copyset的Membership分成三个部分：
* Stray Set - 当前有完整数据的节点集合。
* Acting Set - 当前正在提供服务的节点集合。
* Up Set - Master指定的最新Copyset。
* Epoch - 记录当前Copyset的版本。

#### Chosee Acting

当Copyset启动时，要做的第一件事情就是选活（Choose Acting）。

为此，需要一个Peering过程。

在Up Set和当前Acting Set中的节点都要参与选活：
* 过程类似于Raft选举。
* 每个节点发送自己的Extent Size Sum到其他节点。
* 只有候选人节点的Extent Size Sum至少与当前节点一样大，才会提供投票给候选人。

*NOTE：仔细回想一下，对于每一个写操作，提交之后一定存在于Acting Set的每一个节点中*

当选举出Primary时，Primary就利用当前的信息构造新的Acting Set：
* 首先Primary将自己加入到Acting Set。
* 接着Primary将收到的Extent信息（Extent Size Sum）进行排序：
  * 将前N个与Primary差距小于恢复阈值的节点加入到Acting Set（优先考虑Up Set）。
  * 如果Acting Set满足Acting Size的条件，则选活完成。
  * 如果不满足，就从Up Set中选择足够数量的节点加入Acting Set。
* Primary用新的Acting Set更新Master的信息，并更新Epoch（到这里才算是选举完成，其他节点才能接收Primary的写请求）。
* Up Set中没在Acting Set中的节点加入到Backfill Set（Primary的内存数据）。

*NOTE：同样如果选举超时，需要递增Epoch重新发起，其他节点遇到Epoch比自己大的需要修改自己的Epoch。*

*NOTE：当一个Primary遇到比自己Epoch大的请求也需要Step down。*

*NOTE： 当其他节点遇到新Epoch时（无论是从Peer或Master还是Client），立即停止手头上的工作，拒绝接收当前Epoch的Primary写请求，修改Epoch，等待选举超时。*

#### Recovery

当选活完成之后就需要进行修复：
* Primary对Acting Set中的节点进行Recovery，在这段时间内Acting Set不会提供服务。
* 同时将Backfill Set中的节点加入后台进行回填。
* 当Acting Set中的节点完成Recovery之后，就可以提供服务了。

#### Acting Set Switch

当Primary发现Backfill Set中有节点的数据至少与自己当前的Acting Set中的Stray Node一样新时，发送请求让Master递增Epoch重启Peering过程。

*NOTE： 在Stray Set中且不在Up Set中的节点称为Stray Node。*

#### Cancel Migration

要取消迁移，Master只需要把Up Set设置为当前的Acting Set并递增Epoch即可。

#### Schedule Migration

要发起一次迁移，首先需要取消上一次的迁移。

然后Master设置新的Up Set，同时递增Epoch引发Peering。

## Raft Based System