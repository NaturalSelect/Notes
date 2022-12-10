# Query Execution Part I

## Processing Model

处理模型明确了数据库系统如何去执行一个查询计划。

它会明确我们是从上到下执行还是从下到上执行，以及在Operators之间我们实际应该传递些什么东西。

总共有三种方法，对不同的工作负载和操作环境，它们有不同的取舍，对性能的影响也不同。

## Iterator Model

最常见的模型，所有的数据库都能够这样执行查询。

也叫Volcano Model和Pipeline Model。

每一个Opeator都实现'Next()'函数。

## Materialization Model

主要用于内存数据库。

## Vectorized Model

建立在Iterator Model之上,是对Iterator Model的优化。



## Access Methods

## Expression Evalution