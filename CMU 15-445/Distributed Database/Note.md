# Distributed Database

![F1](./F1.jpg)

## System Architechures

系统架构：
* Shared Everything - 共享一切，常见于单机。
* Shared Memory - 共享内容和磁盘，常见于高性能并行系统（科学计算系统）。
* Shared Disk - 共享磁盘，常见于云原生系统（disk通常指分布式存储）。
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

## Replication

## CAP Theorem

## Distributed OLAP Database

