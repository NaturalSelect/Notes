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

仅追加系统是强一致的（使用Primary-back Replication），只有Primary提供服务，一旦Primary宕掉，则分区只读（掉任何一个节点都会导致只读）。

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
* Election Epoch - 临时Primary选举Epoch，更新的时候做判断。

当该Copyset启动时（每次Copyset信息修改都会导致重启），需要进行Peering：
* Copyset从Up Set + Stray Set中启动，每个节点计算自己的Extent的大小总和，进行选举（根据Extent总大小和Node id），选举出临时Primary。
* 临时Primary收集Stray Set + Up Set的Extent信息，根据Extent总大小和Node id排序选举Acting Set：
  * 将前N个节点加入Acting Set中。
* 接着如果Acting Set改变，临时Primary更新（附上选举EPoch）Master中的Copyset信息（导致Copyset重启，临时Primary退出）。
* 排在Acting Set第一位的节点作为Primary：
  * 将Up Set中但不在Acting Set中的节点加入Backfill Set。
  * 对Acting Set进行前台Backfill。
  * 对Backfill Set进行后台Backfill。
* Acting Set开始对外提供服务。

Primary定时查询Backfill Set中的节点，当其中有节点与Primary的差距小于Primary与某个Stray节点的差距时，则添加到Acting Set，同时逐出一个不在Up Set中的节点（导致Copyset重启）。

当Acting Set与Up Set一致时（顺序无关），将Stray Set更新为Up Set，迁移完成。

## Raft Based System