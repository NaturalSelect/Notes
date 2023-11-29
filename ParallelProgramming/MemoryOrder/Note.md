# Memory Order

流水线和乱序执行是现代CPU的一个重要特征，CPU通过对指令进行重排达到更高的性能而不会对指令的效果产生影响。然而，这仅仅是对于单线程而言的，在并行编程中，不同的线程可能观察到事件以不同的顺序发生。

```cpp
int x = 0;
std::atomic_bool token{false};

void Thread1() {
    x = 1;
    token.store(false,std::memory_order::memory_order_relaxed);
}

void Thread2() {
    while (!token.load(std::memory_order::memory_order_relaxed)) {
        // spin
    }
    // always true?
    assert(x == 1);
}
```

如果CPU重排了指令，将`token`的赋值排序到`x`的赋值之前，`Thread2`的`assert`就会触发。这意味着——**不同的线程可能观察到事件的不同顺序**，对于`Thread1`来说，`x`的赋值在`token`之前（CPU指令重排保证重排不会影响单线程），而对于`Thread2`来说则可能相反。

## Concepts

### Happens-before

在一个线程中，按照程序代码的顺序，先执行的操作 happens-before（先序于） 后执行的操作。

如果操作 x 和操作 y 是同一个线程内的两个操作，并且在代码里 $x$ 先于 $y$ 出现，那么 $x$ happens-before $y$ 。

```cpp
int x;
bool y;

x = 1;
y = true;
```

此处我们称`x = 1` happens-before `y = true`。

### Synchronizes-with

在不同的线程中，如果对单一变量的读操作 $x$ ，读到了写操作 $y$ 写入的值，那么我们称 $x$ synchronizes-with（同步于） $y$ 。

```cpp
std::atomic_int x;
std::atomic_bool y;

void Thread1() {
    x = 1;
    y = true;
}

void Thread2() {
    while (true) {
        // read y
        if (y == true) {
            // `y == true` synchronizes-with `y = true`
        }
    }
}
```

例如此处`y == true`，可能synchronizes-with`y = true`。

## Inter-thread Happens-before

如果在单个线程中，操作 `x = 1` happens-before `y = true`，而操作`y == true` synchronizes-with `y = true`，那么 `x = 1` inter-thread happens-before（跨线程先序于） `y == true`。

```cpp
std::atomic_int x;
std::atomic_bool y;

void Thread1() {
    x = 1;
    y = true;
}

void Thread2() {
    while (true) {
        // read y
        if (y == true) {
            // `y == true` synchronizes-with `y = true`
            // always true!
            assert(x == 1);
        }
    }
}
```

## Acquire Release Order

Acquire Release Order（获取释放顺序）正是基于inter-thread happens-before构建线程间的顺序关系。

```cpp
std::atomic_int x{0};
std::atomic_bool y{false};

void Thread1() {
    x.store(1,std::memory_order::memory_order_relaxed);
    y.store(true,std::memory_order::memory_order_release);
}

void Thread2() {
    while (true) {
        // read y
        if (y.load(std::memory_order::memory_order_acquire) == true) {
            // `y == true` synchronizes-with `y = true`
            // always true!
            assert(x.load(std::memory_order::memory_order_relaxed) == 1);
        }
    }
}
```

* `std::memory_order::memory_order_release` - 发布顺序（用于写操作），任何在该操作之前的写操作不能被重排到该操作之后。
* `std::memory_order::memory_order_acquire` - 获取顺序（用于读操作），任何在该操作之后的读操作不能被重排到该操作之前。
* `std::memory_order::memory_order_acq_rel` - 用于read-modify-write操作（例如FAA和CAS），带有该顺序的操作既是获得顺序又是释放顺序，任何在该操作之前的写操作不能被重排到该操作之后，任何在该操作之后的读操作不能被重排到该操作之前。

利用Acquire Release Order可以构建线程间的顺序链条，确定事件的顺序。