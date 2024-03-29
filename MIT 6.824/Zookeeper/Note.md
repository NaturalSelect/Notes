# Zookeeper

线性化（Lineariazability）：操作在调用和完成操作之间的一个时间点上对整个系统生效，一旦客户端完成对一个数据中心中的对象的写入操作，所有其他数据中心中对同一对象的读取操作将反映其新写入的状态（不允许读到旧数据）。

*NOTE：对于一个线性化的系统，在丢包时返回陈旧的数据是合法的（例如在丢失RPC结果时重传响应，这个响应可能是陈旧的）。*

## Scalability Of Replicated System

在复制系统中，增加`n`倍的服务器可能不会带来`n`倍的性能提升：
1. 在强一致的系统中，只有一个Leader能够处理请求。
2. 由于星型拓扑，性能反而与`n`成反比。

一种提升性能的方法是允许replicas处理读请求，但可能会损失一致性。

Zookeeper的解决方案：不提供线性化的读，只提供线性化的写。

Zookeeper提供两个保证：
* 线性化写入 - 并发的写入以某种确定的顺序原子地执行。
* FIFO Client顺序保证 - Client能够定义操作的执行顺序。

![F1](./F1.jpg)

对于读操作，zookeeper只提供类似“读自己的写”级别的保证：
1. 后续的读操作，不会读到比前面的读操作更早的数据。
2. 在客户端写入时，一定能够在后续的读取中读到自己的写。

对于每一个写操作，zookeeper都使用`zxid`进行编号，在写入时这个编号随着响应返回Client。

Client在读取时，将`zxid`发送给replica，只有该`zxid`的log已被应用的replica才能为Client服务。

同时，在读取操作完成时，replica目前最大的`zxid`也会随着响应返回，Client用这个`zxid`更新自己的`zxid`保证不会读取到更旧的数据。

## Watch Mechanism

![F2](./F2.jpg)

在一个典型的配置更新操作中：

对于配置的更新者（Writer）：

1. 首先删除ready文件。
2. 修改多个配置文件。
3. 然后重新创建ready文件。

然而，此种顺序在zookeeper中，并不够确保配置更新的原子性。

![F3](./F3.jpg)

其他Client可能在读到旧的ready的同时读取到不完全更新的配置文件。

Watch机制被设计出来避免这点。

![F4](./F4.jpg)

在读取时，Client可以同时为某个键设置一个Watch，这样当该键的状态改变，或者replica崩溃时（以便Client重建Watch）都将收到通知。

## The Zookeeper API

![F5](./F5.jpg)

Zookeeper的存储结构与文件系统类似，这些目录和文件称为`znode`。

总共有三种znodes：
* 常规Znode。
* 临时Znode - 与Client session绑定的znode，当Client正常或异常退出时，该znode被删除（这个功能通过Client周期性向zookeeper发送心跳实现）。
* 顺序Znodes - 文件的名称类似`name_{id}`，由zookeeper保证`{id}`唯一且递增。

![F6](./F6.jpg)

每一个znode都有一个递增的版本号。

zookeeper提供了以下API：
* `Create(path,data,flags) -> bool` - 在`path`创建一个具有指定`flag`的znode，并返回是否成功创建（当znode不存在时成功）。
* `Delete(path,version) -> bool` - 删除znode（只有版本与`version`相同时执行）。
* `Exist(path,watch) -> bool` - 判断一个znode是否存在，或/并设置watch。
* `Getdata(path,watch) -> <data,version>` - 获取znode的数据，或/并设置watch。
* `Setdata(path,data,version) -> bool` - 设置znode的数据（只有版本与`version`相同时执行）。
* `GetChildren(path,watch) -> znodes` - 获取目录下的所有`entries`。

利用`EPHEMERAL | SEQUENTIAL`可以实现分布式锁：
* `SEQUENTIAL` - 保证锁的公平并阻止惊群效应。
* `EPHEMERAL` - 保证锁不会丢失。

```c
Lock
1: n = create(1 + "/lock-", EPHEMERAL | SEQUENTIAL)
2: C = getChildren(1, false)
3: if n is lowest znode in C, exit
4: p = znode in C ordered just before n
5: if exists(p, true) wait for watch event
6: goto 2
```

```c
Unlock
1: delete(n)
```

或者更复杂的读写锁。

```c
Write Lock:
1: n = create(1 + "write-", EPHEMERAL|SEQUENTIAL)
2: c = getChildren(1, false)
3: if n is lowest znode in C exit
4: p = znode in C ordered just before n
5: if exists(p, true) wait for event
6: goto 2
```

```c
Read Lock
1: n = create(1 + "read-", EPHEMERAL|SEQUENTIAL)
2: c = getChildren(1, false)
3: if no write znodes lower than n in C, exit
4: p = write znode in C ordered just before n
5: if exists(p, true) wait for event
6: goto 3
```