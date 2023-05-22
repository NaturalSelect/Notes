# Aurora

Aurora是Amazon构建的云数据库。

## History Of Cloud

Amazon在2006年发布了第一个云计算基础设施（IaaS）EC2，EC2在Amzon的机房中运行VMM，并将虚拟机作为一种产品提供给租户。

![F1](./F1.jpg)

租户在其虚拟机上运行Web服务器和数据库管理系统以搭建自己的网站并向外部提供服务。

![F2](./F2.jpg)

Web服务器之类的无状态服务很容易就可以使用EC2进行容错（当崩溃时启动一个新的EC2实例即可），而有状态的存储系统就没这么容易了（当运行虚拟机的物理机磁盘崩溃时租户将失去所有数据）。

因此Amazon提供了 **S3** 来解决数据的存储问题（通过将租户的DB快照备份在S3上），但这会失去制作快照之后的所有更新（因为那些更新没有被备份）。

同时Amazon提供了 **EBS** ，作为一种高可用的存储实现，租户可以将EBS的卷挂载到虚拟机的文件系统上，然后就像在本地文件系统上执行操作一样操作EBS。

![F3](./F3.jpg)

这使得DBMS之类的存储系统，可以进行容错（通过将数据存储在EBS的方式），当运行DBMS的虚拟机崩溃时，只需要重新启动一个EC2实例运行DBMS软件即可（先前的数据都存储在EBS上，DBMS成了一个无状态服务）。

![F4](./F4.jpg)

*NOTE：在一段时间内一个EBS卷只能被挂载到一个EC2实例上。*

通过EBS进行容错的DBMS称为 **RDS**。

![F5](./F5.jpg)

RDS是一种Primary-backup Replication，同时它的replicas分别在不同的AZ（可用区域，available zone）中，并且两个AZ在不同的数据中心（以提供数据中心级容错）。

RDS的问题：
* EBS的通用性要求它模拟成本地磁盘，这将导致DBMS对磁盘的所有写入都被传输。
* 大量的数据传输导致了低性能。

## Quorum Replication

Quorum Replication是一种无主复制协议。

假设有`N`个replicas，当你需要进行写入时，需要对`W`个replicas进行写入，而当你进行读取时，需要同时从`R`个replicas读取，当 $W+R \ge N + 1$ 时，Quorum满足强一致性。

*NOTE：当 $W+R \lt N + 1$ 时，称为宽松Quorum，并且其满足最终一致性（eventual consistency）。*

![F8](./F8.jpg)

Quorum Replication可能会产生冲突（即`R`中返回的数据包含不一致的数据），必须通过一种方式排除`R`返回的旧数据。

一种典型的方式是使用版本号。

![F9](./F9.jpg)

*NOTE：只有版本号仍然会产生冲突（并发写入），因此Lamport Clock（Lamport Timestamp）是更好的选择。*



## Aurora Design

![F6](./F6.jpg)

Aurora解决了EBS低性能的问题，它只传输DBMS进行恢复的关键——WAL（write ahead logging）。

|配置|30分钟内执行的事务总数|IOs/事务比|
|-|-|-|
|RDS（4 Replicated EBS）|780,000|7.4|
|Aurora（6 Replicated Aurora）|27,378,000|0.95|