# Distributed Database

![F1](./F1.jpg)

## System Architechures

系统架构：
* Shared Everything - 共享一切，常见于单机。
* Shared Memory - 共享内容和磁盘，常见于高性能并行系统（科学计算系统）。
* Shared Disk - 共享磁盘，常见于云原生系统、云数据库（disk通常指分布式存储）。
* Shared Nothing - 无共享，常见于分布式系统。

|Shared Everything|Shared Memory|Shared Disk|Shared Nothing|
|-|-|-|-|
|![F2](./F2.jpg)|![F3](./F3.jpg)|![F4](./F4.jpg)|![F5](./F5.jpg)|

Shared Disk系统通常只需要添加一个无状态的worker node就能完成系统扩展。

|Orignal|Extend|
|-|-|
|![F6](./F6.jpg)|![F7](./F7.jpg)|

但在update时，将产生一致性问题，更新者必须通知其他worker node。

|Update Procedure|
|-|
|![F8](./F8.jpg)|
|![F9](./F9.jpg)|

Shared Nothing是分布式DBMS最常用的架构。

|Read A Key|Read Multi-Keys|
|-|-|
|![F10](./F10.jpg)|![F11](./F11.jpg)|

扩展时需要进行数据迁移。

|Orignal|Extend|
|-|-|
|![F12](./F12.jpg)|![F13](./F13.jpg)|

## Design Issues

Homogenous Node vs Heterogenous Node：
* Homogenous Node - 集群中的每一个节点都能执行相同的任务，进行故障转移和预防很容易。
* Heterogenous Node - 集群中的节点不是平等的，特定节点执行特定任务，允许物理节点（机器）运行多个虚拟节点。

data transparency（数据透明性）指应用程序不知道分布式数据库如何切分table和复制table。

## Partitioning Schemes

database partitioning（数据库分区）的方案：
* Naive Table Partitioning - 让每个节点保存一张table。
* Horizonal Partitioning - 大部分DBMS使用这种方案，每个节点保存table的不相交的子集（通过partition key决定tuple属于哪个partition），通常有hash partitioning和range partitioning两种。

shared nothing系统进行physical partitioning，shared disk系统进行logically partition。

|Naive Table Partitioning|Horizonal Hash Partitioning|
|-|-|
|![F19](./F19.jpg)|![F18](./F18.jpg)|

*NOTE:hash partitioning不支持range query，并且迁移比较困难（除非使用consistent hashing）。*

|Logically Partition|Physical Partitioning|
|-|-|
|![F25](./F25.jpg)|![F28](./F28.jpg)|
|![F26](./F26.jpg)|![F29](./F29.jpg)|
|![F27](./F27.jpg)|![F30](./F30.jpg)|

## Consistent Hashing

![F20](./F20.jpg)

查询时，执行hash之后按顺时针找到最近的node。

![F21](./F21.jpg)

*NOTE：key space指前一个分区到下一个分区之间的空间。*

添加新节点时，只需要迁移后一个节点的数据到新节点。

删除节点时，需要把被删除节点的数据迁移到后一个节点。

![F22](./F22.jpg)

可以在consistent hashing中复制：
|Replica|Hashing|
|-|-|
|![F23](./F23.jpg)|![F24](./F24.jpg)|

*NOTE：replica factor（复制因子）指副本的个数。*

## Distributed Concurrency Control

Distributed Transaction（分布式事务）指那些访问多个partition的transaction。

分布式事务通常需要coordinate（协调），有两张方式：
* Centralized - 使用全局协调器，每一个分布式事务都需要通过这个协调器进行，通常使用带middleware的方案。
* Decentralized - 参与事务的节点自己判断是否能够进行该事务，通常在参与者节点中选出一个主节点充当协调者。

|Centralized|Centralized（Middleware）|Decentralized|
|-|-|-|
|![F31](./F31.jpg)|![F36](./F36.jpg)|![F40](./F40.jpg)|
|![F32](./F32.jpg)|![F37](./F37.jpg)|![F41](./F41.jpg)|
|![F33](./F33.jpg)|![F38](./F38.jpg)|![F42](./F42.jpg)|
|![F34](./F34.jpg)|![F39](./F39.jpg)|![F43](./F43.jpg)|
|![F35](./F35.jpg)|-|-|

*NOTE：这里都使用2PC的方式提交。*

## Distributed OLTP Database

![F44](./F44.jpg)

*NOTE：我们假设运行数据库的节点是可信的、友好的、非恶意的。*

*NOTE：如果节点可能出现任意的恶意行为（即出现了拜占庭错误），则称它为拜占庭节点，能容忍拜占庭错误的容错技术称为拜占庭容错（BFT）。*

## Atomic Commit Protocol

当跨越多个节点的事务完成，DBMS需要询问事务的参与者是否能够安全地提交事务。

有以下几种方式：
* Two-Phase Commit（2PC） - 二阶段提交。
* Three-Phase Commit（3PC） - 三阶段提交，已不再使用。
* Paxos - Paxos共识算法。
* Raft - Raft共识算法。
* ZAB（Apache Zookeeper） - ZAB共识算法。
* Viewstamped Replications - VSR共识算法。

*NOTE：通常使用共识算法管理复制，使用2PC进行跨分区的分布式事务。*

2PC分为两个阶段：
* Prepare - 事务的协调者将事务发送给每一个参与者，参与者将查看是否可以提交事务，如果可以提交则参与者做出承诺，绝不在承诺之后拒绝事务（这意味着参与者必须将事务记录到日志中，以在崩溃之后进行恢复）。
* Commit - 事务的协调者必须收集到所有参与者对事务的承诺（否则终止事务）然后记录在自己的log中（保证恢复之后能够commit事务），然后发送提交消息给所有参与者。

|2PC（Success）|2PC（Abort）|
|-|-|
|![F46](./F46.jpg)|![F52](./F52.jpg)|
|![F47](./F47.jpg)|![F53](./F53.jpg)|
|![F48](./F48.jpg)|![F54](./F54.jpg)|
|![F49](./F49.jpg)|![F56](./F56.jpg)|
|![F50](./F50.jpg)|![F57](./F57.jpg)|
|![F51](./F51.jpg)|![F55](./F55.jpg)|

可以对2PC进行两种优化：
* Early Prepare Voting - 如果发送给协调者的查询是事务要执行的最后一个查询，那么可以省略commit request，让协调者直接进入2PC的Prepare阶段（省去一个网络消息）。
* Early Acknowledgement After Prepare - 如果协调者收集到了所有节点的承诺，那么先告诉外部事务已提交再进入commit phase（异步进行提交）。

|Early Acknowledgement After Prepare|
|-|
|![F58](./F58.jpg)|
|![F59](./F59.jpg)|
|![F60](./F60.jpg)|
|![F61](./F61.jpg)|
|![F62](./F62.jpg)|
|![F63](./F63.jpg)|

Paxos工作方式与2PC相似，但只需要大多数的同意。

|Paxos（Suceess）|Paxos（Reject）|
|-|-|
|![F64](./F64.jpg)|![F69](./F69.jpg)|
|![F65](./F65.jpg)|![F70](./F70.jpg)|
|![F66](./F66.jpg)|![F71](./F71.jpg)|
|![F67](./F67.jpg)|![F72](./F72.jpg)|
|![F68](./F68.jpg)|![F73](./F73.jpg)|
|-|![F74](./F74.jpg)|
|-|![F75](./F75.jpg)|
|-|![F76](./F67.jpg)|
|-|![F77](./F77.jpg)|
|-|![F78](./F78.jpg)|

*NOTE:Pasox可能出现live lock，因为算法没有决定proposer的数量，Pasox的变种multi-paxos通过选举一个唯一的proposer（leader）的方式解决了这个问题。*

## Replication

有多种复制方案：
* Master-Replica（leader-follower、master-slave） - 只有一个可写的节点同时该节点负责传播外部的写操作，只有当该机器死亡时，才从其他机器中选择一个接替。
* Multi-Master - 集群中有多个节点可以接受写操作，当写操作产生冲突时决定该使用哪一个写入的值。

K-Safety指当对象的副本数量低于某个指时判断系统为可不用，K代表对象在集群中的副本数量（每个replica只能拥有一个副本）。

对于Master-Replica复制来说，有三种写入的传播方案：
* Asynchronous（Eventual Consistency） - 异步地传播写操作，向外部应答时不需要等待所有replicas完成写操作。
* Synchronous（Strong Consistency） - 同步地传播写操作，只有所有的replicas都完成写操作才向外部应答。
* Half Synchronous - 写操作传播到某个数量（通常是大多数）的replica之前不向外部应答，当一定数量的replica完成写操作后再向外部应答，剩下的replicas则进行异步传播。

写操作传播时机：
* Continuous - 当master收到写入时，立刻将写入传播到replicas（大多数DBMS使用这种）。
* On Commit - 当master收到commit时，才将它产生的写入传播到replica。

事务的落地方式：
* Active-Passive - master将事务的log传播给replicas（先在master上执行）。
* Active-Active - master将事务的SQL语句传播给replicas（同时执行），master和replicas独立地执行语句，最后验证执行的结果是否相同。

## CAP Theorem

一个系统不可能同时拥有CAP特性：
* Consistency - 副本间维持一致（即线性化）。
* Always Available - 永远可用。
* Network Partition Tolerant - 网络分区容忍。

![F81](./F81.jpg)

*NOTE：通常在CP与AP之间进行选择。*

## Federated Databases

Federated Databases（异构联合数据库）指哪些每个节点上运行的DBMS软件不一致的分布式数据库。

通常通过中间件或者foreign data wrapper实现。

|Federated Databases（Middleware）|Federated Databases（Postgresql Foreign Data Wrappers）|
|-|-|
|![F82](./F82.jpg)|![F83](./F83.jpg)|

## Distributed OLAP Database

![F45](./F45.jpg)

OLAP数据库（也叫数据仓库，data warehouse）通常通过ETL从OLTP数据孤岛中提取数据。

![F84](./F84.jpg)

有两种方式对OLAP数据库建模：
* Star Schema - 将table分为fact table和dimension tables，一个fact table保存了所有的event而dimension tables记录了event的详细信息，fact table中存在执行dimension tables的外键，并且只能拥有一层dimension tables。
* Snowflake Schema - 与Star Schema类似但dimension tables允许出现多层。

*NOTE：某些数据库只支持Star Schema。*

|Star Schema|Snowflake Schema|
|-|-|
|![F85](./F85.jpg)|![F86](./F86.jpg)|

Star Schema vs Snowflake Schema：
* Star Schema查询时需要的join更少（这意味着它更快），但非规范化的数据可能引起一致性问题（因为我们会存储本该规范化到其他表中的冗余信息）。
* Snowflake Schema查询时需要的join更多，但不存在非规范化数据的问题。

## Execution Models

执行查询的方式有两种：
* Push Query To Data - 将查询或查询的片段发送到数据所在的地方，在该节点上执行查询（能够进行早期过滤减少网络消息量并且有更好的并行性）然后返还结果给base节点（home节点）。
* Pull Data To Query - 从数据所在的节点中拉取需要查询的数据（常见于shared disk系统，因为这种系统能够避免它的缺点）。

*NOTE：base节点是该查询的协调者。*

*NOTE：在shared disk的系统中push和pull的边界很模糊，shared disk通常会暴露一个支持谓词下推的接口来减少数据量。*

|Push Query To Data（Shared Nothing）|Pull Data To Query（Shared Disk）|Pull Data To Query（Stuipd）|
|-|-|
|![F87](./F87.jpg)|![F90](./F90.jpg)|![F93](./F93.jpg)|
|![F88](./F88.jpg)|![F91](./F91.jpg)|![F94](./F94.jpg)|
|![F89](./F89.jpg)|![F92](./F92.jpg)|-|

## Query Fault Tolerance

大部分（shared nothing）分布式OLAP DBMS不会进行查询容错，当执行查询的节点崩溃，终止查询并返回错误（因为保存查询产生的临时数据的成本非常高）。

容错需要将operator产生的临时数据写到一个所有节点都能访问的位置上（典型地是写入shared disk或者传给replica）。

*NOTE：MapReduce和Hadoop进行容错是因为它们默认跑在廉价机器的集群上。*

某些系统可以手动设置以进行容错（大部分系统不会默认打开容错）。

|Query Fault Tolerance（Shared Disk）|
|-|
|![F95](./F95.jpg)|
|![F96](./F96.jpg)|
|![F97](./F97.jpg)|
|![F98](./F98.jpg)|

## Query Planning

在分布式环境中执行的优化有三种：
* Predicate Pushdown - 谓词下推。
* Early Projections - 提前映射。
* Optimal Join Orderings。

将Query发送给节点的方式：
* Physical Operators - 协调者通过查询优化器生成用于全局的查询计划，将计划的物理操作片段发送到其他节点上，其他节点收到后立即执行（不管操作在当前节点上执行是否是最优的），然后发送结果（目前大多数DBMS使用这种方式）。
* SQL - 协调者在获取SQL之后为每一个分区重写成适合该分区执行的SQL语句，然后发送给各个分区（允许每个分区各自进行查询优化），各个分区执行完后返回结果（只有MemSQL使用了这种方式）。

![F99](./F99.jpg)

## Distributed Join Algorithms

对于查询：

```sql
SELECT * FROM R
JOIN S ON R.id = S.id
```

一共存在四种情况：
* 表S被复制到所有节点，而表R被分区。
* 表S和表R以相同的字段分区，分区的字段是我们进行join的字段。
* 表S和表R以不同的字段分区，表R的分区的字段是我们进行join的字段 - Broadcast Join算法，先将表S复制到每一个节点再执行join。
* 表S和表R以不同（或相同）的字段分区，但是分区的字段不是我们进行join的字段 - Shuffle Join算法（又叫Shuffle Hash Join算法），将表S和R进行重新分区后执行join。

|Replicated Table|Same Field Partitoning|
|-|-|
|![F100](./F100.jpg)|![F103](./F103.jpg)|
|![F101](./F101.jpg)|![F104](./F104.jpg)|
|![F102](./F102.jpg)|![F105](./F105.jpg)|

|Broadcast Join|Shuffle Join|
|-|-|
|![F106](./F106.jpg)|![F111](./F111.jpg)|
|![F107](./F107.jpg)|![F112](./F112.jpg)|
|![F108](./F108.jpg)|![F113](./F113.jpg)|
|![F109](./F109.jpg)|![F114](./F114.jpg)|
|![F110](./F110.jpg)|![F115](./F115.jpg)|
|-|![F116](./F116.jpg)|
|-|![F117](./F117.jpg)|

*NOTE：如果单个分区无法放入单个节点时，查询终止。*

某些DBMS支持Semi-Join（对只需要外表返回的查询进行优化）。

例如：
```sql
SELECT R.id FROM R
 LEFT OUTER JOIN S
   ON R.id = S.id
WHERE R.id IS NOT NULL
```

不会发生实际上的join操作，而是检查存不存在对于id的S tuple，将它重写成：
```sql
SELECT R.id FROM R
WHERE EXISTS (
    SELECT 1 FROM S
    WHERE R.id = S.id
)
```

为了执行这个操作，只需要发送R.id。

|Semi-Join|
|-|
|![F118](./F118.jpg)|
|![F119](./F119.jpg)|

某些DBMS还会提高Semi-Join的关键字（该keyword非SQL标准，通常需要使用`EXISTS`依靠查询优化器来进行semi-join）。

```sql
SELECT R.id FROM R
SEMI JOIN S 
ON R.id = S.id 
```

## Cloud Systems

