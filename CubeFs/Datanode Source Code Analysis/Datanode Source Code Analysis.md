# Datanode Source Code Analysis

每一个数据节点（data node）可以搭载多个数据分区（data partition），每一个数据分区都运行一个Raft组（raft group）和一个主从复制组（primary-backup group），数据节点只对 extent 进行管理而与实际的文件无关。

![F1](./F1.jpg)

卷中（volume）的每一个文件（file）都由一个或多个 extents 存储：
* 对于大文件（large file），单个文件被切分成多个 extents 存储在数据分区中。
* 对于小文件（small file），多个文件聚合成一个 extent 存储在数据分区中。

## Storage Engine

### Large File Storage

![F2](./F2.jpg)

大文件将自身的内容切分成多个 extents ，这些 extents 由数据分区进行存储，这意味着大文件的不同 extents 可以存储在不同数据分区中，从而为随机读/写提高更好的并行性。

### Small File Storage

![F3](./F3.jpg)

多个小文件聚合存储在一个 extent 中，并由元数据节点（meta node）记录该文件在 extent 的offset，当文件删除时，通过 `fallocate()` 进行文件系统打洞来删除文件。

### Sequential Write

![F4](./F4.jpg)

顺序写入通过主从复制进行：
1. Client将要写入的数据传输给主从复制的Leader。
2. Leader将数据复制到多个 replicas 中。
3. 主从集群完成写入，并向Client回复新的 extent 大小（一个整数）。
4. Client用新的 extent 大小更新在元数据分区（meta partition）中的文件大小。

*NOTE：步骤 4 是整个写入过程的提交点（commit point）。*

在故障恢复时：主从复制进行 extent 大小的对齐（取最小值）。

### Random Write

![F5](./F5.jpg)

随机写入通过Raft组进行：
1. Client将写入的数据传输给Raft组的Leader。
2. Leader将其放入Raft Log中，并传输给其他replicas。
3. Raft组应用log entry，并向Client返回。

### Disk Data Structure

每一个数据分区在本地文件系统上都会有自己的目录。

对于：
* 正常数据分区 - 标准卷的分区，目录名为 `datapartition_<partitionId>_<partitionSize>`。
* 缓存数据分区 - 低频卷的分区，目录名为 `cachepartition_<partitionId>_<partitionSize>`。
* 预热数据分区 - 存储预热数据的卷的分区，目录名为 `preloadpartition_<partitionId>_<partitionSize>`。
* 过期数据分区 - 已经从该节点移走的卷的数据分区，目录名为 `expired_datapartition_<partitionId>_<partitionSize>`。

![F6](./F6.jpg)

每间隔一段固定的时间（2分钟），数据节点会对`.diskStatus`隐藏文件进行一次读写来判断当前磁盘是否可用。

具体的数据分区目录结构如下：

![F7](./F7.jpg)

其中：
* `1` - `100` 为该数据分区存储的 extents 文件，文件名就是 extent 的 id。
* APPLY - 记录数据分区当前的Raft `AppiledIndex`的值。
* EXTENT_CRC - 记录每一个 extent 的 checksum。
* EXTENT_META - 前`8`个字节记录正在使用的最大的 extent id，后`8`个字节记录已经分配的 extent id的最大值。
* META - 记录数据分区的元数据信息。
* NORMALEXTENT_DELETE - 记录被删除的 extent id。
* TINYEXTENT_DELETE - 记录被删除的extent 信息（`|ExtentId|offset|size|`，每条24字节）。
* wal_2181 - Raft的log目录。


extent 文件具有两种类型：
* **NormalExtent** - 由`128KB`的块组成，每一个 extent 不能拥有超过`1024`个块，所以此种 extent 最大的大小为 `128MB`，此种 extent 的id从`1024`开始分配。
* **TinyExtent** - 此种 extent 的最大大小为`4TB`，负责存储小文件，每个小文件的数据都对齐到`4096`，此种 extent 的id从`1`开始分配到`64`。

### DataNode Data Structure

![F8](./F8.jpg)

每一个数据分区都使用一个空间管理器（space manager）进行空间管理。

![F9](./F9.jpg)

