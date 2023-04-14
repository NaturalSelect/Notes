# Datanode Source Code Analysis

每一个数据节点（data node）可以搭载多个数据分区（data partition）。

每一个数据分区都运行一个Raft组（raft group）和一个主从复制组（primary-backup group）。

![F1](./F1.jpg)

