# Distributed Transactions

将数据分片到多个不同的机器是非常常见的行为，这样就能减低每个机器处理和存储容量上的压力，提高可扩展性。

分布式事务能够很好地隐藏分片存储的复杂度，使得系统对外表现如同没有进行分片。

*NOTE：只在一个机器（进程）上进行的事务不是分布式事务，是“单键事务”。*

### Concurrency Control

对于并发控制来说，总共有两种方案：
* 悲观并发控制。
* 乐观并发控制。

## Atomic Commit

原子提交协议（atomic commit protocol）判断每一个分片是否都能提交事务，保证事务提交的原子性。

### Two-Phase Commit

二阶段提交（Two-Phase Commit，2PC）分为两个阶段：
* Prepare
* Commit

有一个节点对事务进行协调，称为事务协调者（coordinator）或者master，其他节点称为参与者（participants）、cohort或者 worker。

![F1](./F1.jpg)

*NOTE：协调者也可以作为参与者。*

每一个事务都有一个事务id（transaction id，TID），协调者在开启事务之前，将分配一个唯一的事务id给事务。

#### Prepare Phase

协调者在Prepare阶段将属于每一个分片的请求发送给每一个分片：
* 对于读请求，分片立即执行，并返回结果。
* 对于写请求，分片将持久化该请求。

然后向每一个分片发送`PREPARE`消息：
* 如果参与者能够执行先前协调者发送来的全部请求，回复`YES`。
* 否则，回复`NO`。

*NOTE：这是为了确保参与者确实有执行写操作的能力。*

![F2](./F2.jpg)

协调者等待每一个参与者的回复，然后进入Commit阶段。

#### Commit Phase

如果每一个参与者都回复`YES`，那么协调者将提交事务：
* 向每一个参与者发送`COMMIT`消息。
* 参与者收到之后将提交事务，并释放事务占用的资源（例如锁）。
* 然后向协调者回复`ACK`。

![F4](./F4.jpg)

否则，协调者终止事务：
* 向每一个参与者发送`ABORT`消息。
* 参与者收到之后将终止事务，并释放事务占用的资源（例如锁）。
* 然后向协调者回复`ACK`。

最后协调者将向客户端返回事务执行的结果。


#### Fault Tolerance

当参与者故障并重启：
* 如果未对`PREPARE`回复`YES`，则放弃事务。
* 如果已经对`PREPARE`回复`YES`，则不能放弃事务（所以必须先持久化请求和`PREPARE`消息的响应再发送响应），并等待来自协调者的响应（可能需要主动发起请求询问，因为可能已经收到过协调者对事务的`COMMIT`消息但丢失了）。

![F5](./F5.jpg)


当协调者故障并重启：
* 如果事务未达到`COMMIT`阶段，则中止事务。
* 如果已经发送`COMMIT`但没有收到所有`ACK`的事务不能被丢弃，协调者必须重新发送`COMMIT`响应直到收到所有`ACK`。
* 如果已经发送`ABORT`但没有收到所有`ACK`的事务不能被丢弃，协调者必须重新发送`ABORT`响应直到收到所有`ACK`。

*NOTE：`COMMIT`和`ABORT`都存在多轮的重发。*

*NOTE：在决定事务`COMMIT`还是`ABORT`之前，协调者必须持久化事务。*

![F6](./F6.jpg)

当协调者遇到参与者崩溃时或消息丢失时：
* 如果`PREPARE`无响应，则重发`PREPARE`，直到获得响应（或者简单地中止事务）。
* 如果`COMMIT`或`ABORT`无响应，**协调者必须等待直到获得所有响应**。

*NOTE：当协调者得到他不知道的事务的`PREPARE`响应时，发送`ABORT`给发送该响应的参与者。*

当参与者遇到协调者崩溃或消息丢失时：
* 如果未对`PREPARE`回复`YES`，则放弃事务。
* 如果已经对`PREPARE`回复`YES`，**则必须等待直到遇到`COMMIT`或者`ABORT`**。

![F7](./F7.jpg)

*NOTE：当参与者得到他不知道的事务的`PREPARE`消息时，回复`NO`。*

对事务的协调者和参与者进行复制可以减少故障的产生，增强性能。

![F8](./F8.jpg)

## Percolator Style Transaction

## Spanner Style Transaction

## FaRM Style Transaction