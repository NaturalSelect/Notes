# Cache Consistency

## Frangipani Style Cache

Frangipani是一个早期的分布式文件系统。它将多台机器上的磁盘集合管理为一个共享存储池。假定这些机器处于共同的管理之下，并且能够安全地通信，它是为小团体共享文件设计的。

![F1](./F1.jpg)

Frangipani分为两层：
* 一层是在kernel中的Frangipani模块（类似fuse），扮演了Client。
* 一层是Petal，这是一个分布式块存储系统（称为虚拟磁盘）。

Client会将block的副本存储在本地作为缓存，以减低文件操作的时延。

同时Frangipani使用Write-Back Caching（写回缓存），block在被修改后不会立即被写入到Petal，只有当必要时才被写入Petal，这使得文件操作能够非常快速地完成。

然而Frangipani被期望具有强一致性（多个Client之间缓存一致性的需要），Frangipani使用了一种复制的锁机制实现了这点，同时系统被期望能够进行单个原子性的文件操作。

### Cache Coherence Protocol

Frangipani的缓存一致性是通过锁实现的，在Frangipani中有一种lock server。

每一个lock server都存储了一张表，表的每一项记录了文件的`inode number`，锁的owner。

![F2](./F2.jpg)

*NOTE： 实际上Frangipani支持更复杂的锁方案（例如读写锁），所有这里的表项并不全面。*

同时每个Client必须跟踪它拥有的锁，所以它也有一张类似的表。

当Client要去读取文件或目录时：
* 先向lock server请求对应的锁。
* 询问petal获得文件对应的block。
* 将锁记录在自己的表中。

![F3](./F3.jpg)

Client表中的锁有两种状态：
* BUSY - 某个系统调用正在使用锁。
* IDLE - 锁空闲（这并不意味着锁已经归还）。

*NOTE：只有Client拥有锁，才允许被缓存对应的数据（操作数据之前必须先获得锁）。*

![F4](./F4.jpg)

对于一个获取锁的请求，lock server将进行以下处理：
* 如果锁没有被持有直接返回。
* 如果锁被其他人持有，lock server向其发生一个`REVOKE`消息，要求他释放锁。

当一个Client收到`REVOKE`时：
* 如果锁的状态是BUSY，先等待操作完成。
* 如果数据是脏的，先将数据写入到petal。
* 释放锁。

![F5](./F5.jpg)

*NOTE：除了通过`REVOKE`释放锁会导致写入之外，Client每30秒将数据写入一层petal，防止因Client崩溃导致数据丢失（只损失30秒的数据是可以接受的）。*

### Transaction

为了保证多步操作（petal是个模拟磁盘的块存储）的原子性，Frangipani使用锁构建了事务系统。

在操作开始前，Frangipani会获得操作所需要的所有的锁，然后再进行操作（类似SS2PL）。

![F6](./F6.jpg)

### Crash With Locks

Client可能在进行复杂操作时崩溃，而部分数据可能已经被写入到了petal。

Frangipani使用WAL（write ahead logging）实现崩溃恢复。

*NOTE： Frangipani的logging没有commit，需要原子性的操作必须聚合成一个entry。*

Client在开始操作之前，先往petal写入log entries，只有当所有log entries顺利持久化之后才会将数据写入到petal。

在Frangipani中，不同Client之间的log是分开的，并且这些logs存放在petal上。

每个log entry包含：
* 一个序列号（LSN）。
* 写入的block的id。
* 版本号。
* 要写入的数据。

![F7](./F7.jpg)

log entries一开始存储在Client上，只有Client需要释放锁时（包含收到`REVOKE`和经过30秒），才会将log entries写入到petal。

![F8](./F8.jpg)

当lock server向Client发生`REVOKE`，而Client超过一段时间没有任何回复（没有释放也没有heartbeat），lock server判定Client崩溃，当Client持有锁时崩溃：
* lock server寻找一个存活的Client。
* 该Client读取崩溃Client的日志并进行replay。
* 完成后向lock server报告。
* lock server释放锁。

每一个log entry都带有一个版本号标记block的新版本，只有当block的版本小于这个值时，才会执行redo。

*NOTE：这在释放多个锁时崩溃的情况下十分常见。*

![F9](./F9.jpg)

进行恢复Client并不需要获得锁：
* 当只持有一个或多个锁的Client崩溃时，恢复Client总是进行独占访问。
* 当持有多个锁的Client崩溃并且崩溃的Client已经释放了一部分锁时，Client只需要redo它未释放锁的log entries（因为已经释放的锁的block的version会大于log entry中的值所以不会redo）。

## Facebook Memcached Style Cache

Memcached 是一个知名的，简单的，全内存的缓存方案。Facebook对Memcached进行调整以构建和扩展一个分布式的 key-value存储来为世界上最大的社交网站服务的。

### The Evolution Of Web Application Architecture

任何网站都是从小型网站演化而来的，在一开始只需要在一台机器上运行web service（front end）和database并向外部提供服务。

![F10](./F10.jpg)

随着网站变得流行，单一的front end成为瓶颈，架构演化成多个front end和一个database的模式，以提供更多的CPU处理能力。

*NOTE：此时瓶颈仍在处理从database得到的数据并返回给user，而不在database。*

![F11](./F11.jpg)

随着越来越多的front end，database逐渐变成瓶颈，需要使用分片对database进行拆分。

![F12](./F12.jpg)

为了获得更快的响应速度，减低读取数据的延迟而引用缓存层：
* front end将首先从缓存中读取。
* 如果front end未从缓存中获取数据再从数据库读取，读取完成后插入缓存以加速后面的读取。

![F13](./F13.jpg)

对于缓存来说，强一致性并不重要，但至少需要保证用户能够读到自己的写入，并且数据落后的不能太多。

### Facebook Architecture

Facebook有两个数据中心，一个在美国西海岸，一个在东海岸。

*NOTE：每一个数据中心称为region。*

![F14](./F14.jpg)

每一个数据中心都部署相同的服务：
* Mysql。
* Memcached。
* Front End Web Server。

一个数据中心中的Mysql作为primary database另一个数据中心则作为backup，数据中心的Mysql之间通过异步复制进行复制，缓存层作为look-aside cache，并且使用失效策略（invalidation scheme）保证一致性。

|失效策略（invalidation scheme）| |更新策略（update scheme）| |
|-|-|-|-|
|Read|Write|Read|Write|
|![F15](./F15.jpg)|![F16](./F16.jpg)|![F15](./F15.jpg)|![F18](./F18.jpg)|

*NOTE：使用更新策略需要分布式锁。*

![F17](./F17.jpg)

同时无论是异步复制还是正常的更新操作都会删除缓存。

*NOTE：在front end中主动delete缓存是必要的，因为database删除缓存存在延迟。*

### Performance

Facebook对memcached做了两种调整以获得高性能：
* Partition（分区） - 对键进行hash，将不同hash的键分配到不同的机器上以获取更好的并行性。
* Replication（复制） - 对每一个分区进行复制防止负载集中到一台机器上，并减少热点的影响。

复制不仅发生在region之间，在同一个region也进行复制。

![F20](./F20.jpg)

*NOTE：这就是为什么正常的更新操作也需要删除缓存。*

为了节省内存，将不正常热的键存储在region集群间共享的region pool中。

![F21](./F21.jpg)

对于新集群为了防止大量的cache miss导致database过载，front end还必须支持cold start：
* 首先从本地集群的memcahced中获取数据。
* 如果miss，则从本地数据中心的另一个集群的memcached中获取数据。
* 最后才到database获取数据。

当新集群的memcached足够热时，再退出cold start模式。

### Thundering Herb

如果一个hot key被写入，可能导致多个front end并行读取database，产生大量的负载，这种现象称为惊群效应（thundering herb）。

|Thundering Herb|
|-|
|![F22](./F22.jpg)|
|![F23](./F23.jpg)|

为了解决这个问题，Facebook设计了memcached lease机制。

这个机制像分布式锁一样工作，只有第一个front end被允许去获取database的数据，而其他的front end必须等待lease timeout。

*NOTE：同时对cache的删除将会导致lease失效，这样被重新排序的更新（即`Read`的`Set`有可能被重排到更新的`Write`的`Delete`后面）将被memcached忽略。*

|Lease|
|-|
|![F24](./F24.jpg)|
|![F25](./F25.jpg)|
|![F26](./F26.jpg)|
|![F27](./F27.jpg)|

### Gutter Server

如果一个memcached server故障，会导致front end产生大量的读取请求发送到服务器。

为了防止database过载，Facebook对故障的memcached进行重定向到一个临时的gutter server。

![F28](./F28.jpg)

*NOTE：同时database的delete也需要发送到所有的gutter server，因为任何一个gutter server都可以替换故障的memcached。*