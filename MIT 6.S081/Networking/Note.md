# Networking

LAN（Local Area Network）的基本结构：
![F1](./F1.jpg)

* 一个以太网交换机。
* 多个host通过以太网交换机进行通信。

![F2](./F2.jpg)

当通信对象不在同一个LAN中，则需要多个router进行转发。

*NOTE:在LAN中使用以太网协议，网际通信使用Internet Protocol。*

## Ethernet Protocol

Eth Frame的首部：

![F3](./F3.jpg)

* `dhost` - 6字节目标host MAC地址。
* `shost` - 6字节源host MAC地址。
* `type` - frame的类型。

![F4](./F4.jpg)

Payload（有效载荷）紧接着首部组成一个Eth Frame。

*NOTE:SFD和FCS用于硬件标记该packet的开始和结束。*

*NOTE:处理Preamble、SFD和FCS由硬件复杂，对kernel是透明的。*

在MAC（48bits）中，前24bits是NIC制造商，后24bits是制造商提供的任意数字（它们可能是连续的序列号）。

Eth交换机收到packet后，会广播到每一个LAN的host上。

*NOTE:`dhost`的`0xFFFFFFFFFFFF`代表all hosts。*

## Arp（Address Resolution Protocol） Packet

![F5](./F5.jpg)

ARP packet由几个部分组成：
* `hrd` - 2字节硬件地址格式（通常是MAC）。
* `pro` - 2字节协议地址格式（通常是IP和IPv6）。
* `hln` - 1字节硬件地址长度。
* `pln` - 1字节硬件地址长度。
* `op` - 2字节操作类型。
* `sender address` - 发送者的硬件地址和协议地址。
* `target address` - 目标的硬件地址和协议地址。

![F6](./F6.png)

总共有两种操作类型：
* Request - 请求某个协议地址的硬件地址。
* Reply - 对某个请求的回复。

