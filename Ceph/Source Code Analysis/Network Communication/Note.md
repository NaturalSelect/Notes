# Network Communication Module Source Code Analysis

网络通信模块的实现在源代码`src/msg`的目录下，其首先定义了一个网络通信的框架。

三个子目录里分别对应：Simple、Async、XIO三种不同的实现方式：
* Simple是比较简单，目前比较稳定的实现，系统默认的用于生产环境的方式。它最大的特点是：每一个网络链接，都会创建两个的线程，一个专门用于接收，一个专门用于发送。
* Async模式使用了基于事件的I/O多路复用模式。这是目前网络通信中广泛采用的方式。
* XIO方式使用了开源的网络通信库accelio来实现。目前也处于试验阶段。

*NOTE： 目前版本只有Async方式。*

## Message

Message是所有消息的基类，任何要发送的消息，都要继承该类。

![F1](./F1.png)

消息的结构如下：
* header是消息头。
* user_data是用于要发送的实际数据
* footer是一个消息的结束标记，附加了一些crc校验数据和消息结束标志。

## Connection

Connection对应端（port）对端的socket的封装。

其最重要的功能就是发送消息：

```cpp
virtual int send_message(Message *m) = 0;
```

## Dispatcher

Dispatcher是消息分发的接口。

Server端注册该Dispatcher类用于把接收到的Message请求分发给具体处理的应用层。Client端需要实现一个Dispatcher函数，用于处理收到的ACK应对消息。

```cpp

```

## Messenger

Messenger是整个网络抽象模块，定义了网络模块的基本API接口。

```cpp
virtual int send_message(Message *m, const entity_inst_t& dest) = 0;

void add_dispatcher_head(Dispatcher *d);
```

## Network Connection Policy

Policy定义了Messenger处理Connection的一些策略。

```cpp
template<class ThrottleType>
struct Policy {
  // 如果为true，该当该连接出现错误时就删除
  bool lossy;
  // 如果为true，底层链接断开时，不会在这段重新建立（等待另一端重建）
  bool server;
  // 如果为true，当连接空闲时等待而不是断开
  bool standby;
  // 如果为true，检测连接reset，并尝试重连
  bool resetcheck;

  /// Server: register lossy client connections.
  bool register_lossy_clients = true;

  // 一些限速设置
  // The net result of this is that a given client can only have one
  // open connection with the server.  If a new connection is made,
  // the old (registered) one is closed by the messenger during the accept
  // process.

  /**
   *  The throttler is used to limit how much data is held by Messages from
   *  the associated Connection(s). When reading in a new Message, the Messenger
   *  will call throttler->throttle() for the size of the new Message.
   */
  ThrottleType* throttler_bytes;
  ThrottleType* throttler_messages;

  // 本地支持的features
  uint64_t features_supported;
  // 对端需要的features
  uint64_t features_required;
}
```