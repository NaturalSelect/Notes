# Local Object Storage

## Introduction

![F1](./F1.png)

Ceph早期的单机对象存储引擎是FileStore，为了维护数据的一致性，写入之前数据会先写Journal，然后再写到文件系统，会有一倍的写放大，而同时现在的文件系统一般都是日志型文件系统(ext系列、xfs)，文件系统本身为了数据的一致性，也会写Journal，此时便相当于维护了两份Journal；另外FileStore是针对HDD的，并没有对SSD作优化，随着SSD的普及，针对SSD优化的单机对象存储也被提上了日程，BlueStore便由此应运而出。

BlueStore便是一个事务型的本地日志文件系统。因为面向下一代全闪存阵列的设计，所以BlueStore在保证数据可靠性和一致性的前提下，需要尽可能的减小日志系统中双写带来的影响。

全闪存阵列的存储介质的主要开销不再是磁盘寻址时间，而是数据传输时间。因此当一次写入的数据量超过一定规模后，写入Journal盘(SSD)的延时和直接写入数据盘(SSD)的延迟不再有明显优势，所以Journal的存在性便大大减弱了。但是要保证OverWrite(覆盖写)的数据一致性，又不得不借助于Journal，所以针对Journal设计的考量便变得尤为重要了。

一个可行的方式是使用增量日志。针对大范围的覆盖写，只在其前后非磁盘块大小对齐的部分使用Journal，即RMW，其他部分直接重定向写COW即可。

## Concepts

`BlockSize`是磁盘IO操作的最小单元(原子操作)。HDD为`512B`，SSD为`4K`。即读写的数据就算少于`BlockSize`，磁盘IO的大小按`BlockSize`对齐，一个`BlockSize`的I/O操作是原子操作，要么写入成功，要么写入失败，即使掉电不会存在部分写入的情况，但多个`BlockSize`存在只写入前面`N`个`BlockSize`的情况。

RWM(Read-Modify-Write)指当覆盖写发生时，如果本次改写的内容不足一个`BlockSize`，那么需要先将对应的块读上来，然后再内存中将原内容和待修改内容合并，最后将新的块写到原来的位置。但是RMW也带来了两个问题：

* 需要额外的读开销；
* 是RMW不是原子操作，如果磁盘中途掉电，会有数据损坏的风险。

为此我们需要引入Journal，先将待更新数据写入Journal，然后再更新数据，最后再删除Journal对应的空间，但者又引入了写放大，Bluestore将写放大控制在较小的范围内，只有非对齐部分使用RMW。

COW(Copy-On-Write)指当覆盖写发生时，不是更新磁盘对应位置已有的内容，而是新分配一块空间，写入本次更新的内容，然后更新对应的地址指针，最后释放原有数据对应的磁盘空间。理论上COW可以解决RMW的两个问题，但是也带来了其他的问题：

* COW机制破坏了数据在磁盘分布的物理连续性。经过多次COW后，读数据的顺序读将会便会随机读。
* 针对小于块大小的覆盖写采用COW会得不偿失：
  * 将新的内容写入新的块后，原有的块仍然保留部分有效内容，不能释放无效空间，而且再次读的时候需要将两个块读出来做Merge操作，才能返回最终需要的数据，将大大影响读性能。
  * 存储系统一般元数据越多，功能越丰富，元数据越少，功能越简单。而且任何操作必然涉及元数据，所以元数据是系统中的热点数据。COW涉及空间重分配和地址重定向，将会引入更多的元数据，进而导致系统元数据无法全部缓存在内存里面，性能会大打折扣。

## Architecture

基于以上设计理念，BlueStore的写策略综合运用了COW和RMW策略。非覆盖写直接分配空间写入即可；块大小对齐的覆盖写采用COW策略；小于块大小的覆盖写采用RMW策略。

核心模块：
* BlockDevice - 物理块设备，使用`libaio`操作的磁盘。
* RocksDB - 存储WAL、对象元数据、对象扩展属性Omap、磁盘分配器元数据。
* BlueRocksEnv - 封装RocksDB文件操作的接口，实现了`RocksDB::Env`接口，给RocksDB用。
* BlueFS - 小型的Append文件系统，作为RocksDB的底层存储。
* Allocator - 磁盘分配器，负责高效的分配磁盘空间（当前实现是bitmap）。

## BlueFS

RocksDB是基于本地文件系统的，但是文件系统的许多功能对于RocksDB不是必须的，所以为了提升RocksDB的性能，需要对本地文件系统进行裁剪。最直接的办法便是为RocksDB量身定制一套本地文件系统，BlueFS便应运而生。

BlueFS是个简易的用户态日志型文件系统，实现了`RocksDB::Env`所有接口。BlueFS在设计上支持把`.log`和`.sst`分开存储，`.log`使用速度更快的存储介质(NVME等)。

BlueStore将所有存储空间从逻辑上分了3个层次：
* 慢速空间(Block)：存储对象数据，可以使用HDD，由BlueStore管理。
* 高速空间(DB)：存储RocksDB的`sst`文件，可以使用SSD，由BlueFS管理。
* 超高速空间(WAL)：存储RocksDB的`log`文件，可以使用NVME，由BlueFS管理。

相对于POSIX文件系统有以下几个优点：
* 元数据结构简单，使用两个map(dir_map、file_map)即可管理文件的所有元数据。
* 由于RocksDB只需要追加写，所以每次分配物理空间时进行提前预分配，一方面减少空间分配的次数，另一方面做到较好的空间连续性。
* 由于RocksDB的文件数量较少，可以将文件的元数据全部加载到内存，从而提高读取性能。
* 多设备支持，BlueFS将存储空间划分了3个层次：Slow慢速空间(存放BlueStore数据)、DB高速空间(存放sstable)、WAL超高速空间(存放WAL、自身Journal)，空间不足或空间不存在时可自动降级到下一层空间。
* 新型硬件支持，抽象出了`block_device`，可以支持`libaio`、`io_uring`、SPDK、PMEM、NVME-ZNS。

BlueFS的数据结构比较简单，主要包含三部分：
* superblock - 主要存放BlueFS的全局信息以及日志的信息，其位置固定在BlueFS的头部4K。
* journal - 存放元数据操作的日志记录，一般会预分配一块连续区域，写满以后从剩余空间再进行分配，在程序启动加载的时候逐条回放journal记录，从而将元数据加载到内存。也会对journal进行压缩，防止空间浪费、重放时间长。压缩时会遍历元数据，将元数据重新写到新的日志文件中，最后替换日志文件。
* data - 实际的文件数据存放区域，每次写入时从剩余空间分配一块区域，存放sstable文件的数据。

BlueFS元数据主要包含：
* superblock。
* dir_map。
* file_map
* 文件到物理地址的映射关系。

每个文件的数据在物理空间上的地址由若干个extents表示。

一个extent包含`bdev`、`offset`和`length`三个元素，`bdev`为设备标识。

```cpp
struct bluefs_extent_t {
  uint64_t offset = 0;
  uint32_t length = 0;
  uint8_t bdev;
};
```

因为BlueFS将存储空间设备划分为三层：慢速（Slow）空间、高速（DB）空间、超高速（WAL），`bdev`即标识此extent在哪块设备上，`offset`表示此extent的数据在设备上的物理偏移地址，`length`表示该块数据的长度。

```cpp
struct bluefs_fnode_t {
    uint64_t ino;
    uint64_t size;
    utime_t mtime;
    uint8_t __unused__;   // was prefer_bdev
    mempool::bluefs::vector<bluefs_extent_t> extents;

    // precalculated logical offsets for extents vector entries
    // allows fast lookup for extent index by the offset value via upper_bound()
    mempool::bluefs::vector<uint64_t> extents_index;

    uint64_t allocated;
};
```
### Mount

```cpp
int BlueFS::mount() {
    dout(1) << __func__ << dendl;

    int r = _open_super();
    if (r < 0) {
        derr << __func__ << " failed to open super: " << cpp_strerror(r) << dendl;
        goto out;
    }

    // set volume selector if not provided before/outside
    if (vselector == nullptr) {
        vselector.reset(
            new OriginalVolumeSelector(get_block_device_size(BlueFS::BDEV_WAL) * 95 / 100,
                                       get_block_device_size(BlueFS::BDEV_DB) * 95 / 100,
                                       get_block_device_size(BlueFS::BDEV_SLOW) * 95 / 100));
    }

    _init_alloc();
    _init_logger();

    r = _replay(false, false);
    if (r < 0) {
        derr << __func__ << " failed to replay log: " << cpp_strerror(r) << dendl;
        _stop_alloc();
        goto out;
    }

    // init freelist
    for (auto &p : file_map) {
        dout(30) << __func__ << " noting alloc for " << p.second->fnode << dendl;
        for (auto &q : p.second->fnode.extents) {
            bool is_shared = is_shared_alloc(q.bdev);
            ceph_assert(!is_shared || (is_shared && shared_alloc));
            if (is_shared && shared_alloc->need_init && shared_alloc->a) {
                shared_alloc->bluefs_used += q.length;
                alloc[q.bdev]->init_rm_free(q.offset, q.length);
            } else if (!is_shared) {
                alloc[q.bdev]->init_rm_free(q.offset, q.length);
            }
        }
    }
    if (shared_alloc) {
        shared_alloc->need_init = false;
        dout(1) << __func__ << " shared_bdev_used = " << shared_alloc->bluefs_used << dendl;
    } else {
        dout(1) << __func__ << " shared bdev not used" << dendl;
    }

    // set up the log for future writes
    log_writer = _create_writer(_get_file(1));
    ceph_assert(log_writer->file->fnode.ino == 1);
    log_writer->pos = log_writer->file->fnode.size;
    dout(10) << __func__ << " log write pos set to 0x" << std::hex << log_writer->pos << std::dec
             << dendl;

    return 0;

out:
    super = bluefs_super_t();
    return r;
}
```

主要流程：
* 加载superblock到内存（`_open_super`）。
* 初始化各存储空间的块分配器（`_init_alloc`）。
* 日志回放建立dir_map、file_map来重建整体元数据（`_replay(false, false)`）。
* 标记已分配空间：BlueFS没有像BlueStore那样使用FreelistManager来持久化分配结果，因为sstable大小固定从不修改，所以BlueFS磁盘分配需求都是比较同意和固定的。会遍历每个文件的分配信息，然后移除相应的磁盘分配器中的空闲空间，防止已分配空间的重复分配。

### Open File

```cpp
int BlueFS::open_for_read(std::string_view dirname,
                          std::string_view filename,
                          FileReader **h,
                          bool random) {
    std::lock_guard l(lock);
    dout(10) << __func__ << " " << dirname << "/" << filename
             << (random ? " (random)" : " (sequential)") << dendl;
    map<string, DirRef>::iterator p = dir_map.find(dirname);
    if (p == dir_map.end()) {
        dout(20) << __func__ << " dir " << dirname << " not found" << dendl;
        return -ENOENT;
    }
    DirRef dir = p->second;

    map<string, FileRef>::iterator q = dir->file_map.find(filename);
    if (q == dir->file_map.end()) {
        dout(20) << __func__ << " dir " << dirname << " (" << dir << ") file " << filename
                 << " not found" << dendl;
        return -ENOENT;
    }
    File *file = q->second.get();

    *h = new FileReader(file, random ? 4096 : cct->_conf->bluefs_max_prefetch, random, false);
    dout(10) << __func__ << " h " << *h << " on " << file->fnode << dendl;
    return 0;
}
```

```cpp
int BlueFS::open_for_write(std::string_view dirname,
                           std::string_view filename,
                           FileWriter **h,
                           bool overwrite) {
    std::lock_guard l(lock);
    dout(10) << __func__ << " " << dirname << "/" << filename << dendl;
    map<string, DirRef>::iterator p = dir_map.find(dirname);
    DirRef dir;
    if (p == dir_map.end()) {
        // implicitly create the dir
        dout(20) << __func__ << "  dir " << dirname << " does not exist" << dendl;
        return -ENOENT;
    } else {
        dir = p->second;
    }

    FileRef file;
    bool create = false;
    bool truncate = false;
    map<string, FileRef>::iterator q = dir->file_map.find(filename);
    if (q == dir->file_map.end()) {
        if (overwrite) {
            dout(20) << __func__ << " dir " << dirname << " (" << dir << ") file " << filename
                     << " does not exist" << dendl;
            return -ENOENT;
        }
        file = ceph::make_ref<File>();
        file->fnode.ino = ++ino_last;
        file_map[ino_last] = file;
        dir->file_map[string{filename}] = file;
        ++file->refs;
        create = true;
    } else {
        // overwrite existing file?
        file = q->second;
        if (overwrite) {
            dout(20) << __func__ << " dir " << dirname << " (" << dir << ") file " << filename
                     << " already exists, overwrite in place" << dendl;
        } else {
            dout(20) << __func__ << " dir " << dirname << " (" << dir << ") file " << filename
                     << " already exists, truncate + overwrite" << dendl;
            vselector->sub_usage(file->vselector_hint, file->fnode);
            file->fnode.size = 0;
            for (auto &p : file->fnode.extents) {
                pending_release[p.bdev].insert(p.offset, p.length);
            }
            truncate = true;

            file->fnode.clear_extents();
        }
    }
    ceph_assert(file->fnode.ino > 1);

    file->fnode.mtime = ceph_clock_now();
    file->vselector_hint = vselector->get_hint_by_dir(dirname);
    if (create || truncate) {
        vselector->add_usage(file->vselector_hint, file->fnode);   // update file count
    }

    dout(20) << __func__ << " mapping " << dirname << "/" << filename << " vsel_hint "
             << file->vselector_hint << dendl;

    log_t.op_file_update(file->fnode);
    if (create)
        log_t.op_dir_link(dirname, filename, file->fnode.ino);

    *h = _create_writer(file);

    if (boost::algorithm::ends_with(filename, ".log")) {
        (*h)->writer_type = BlueFS::WRITER_WAL;
        if (logger && !overwrite) {
            logger->inc(l_bluefs_files_written_wal);
        }
    } else if (boost::algorithm::ends_with(filename, ".sst")) {
        (*h)->writer_type = BlueFS::WRITER_SST;
        if (logger) {
            logger->inc(l_bluefs_files_written_sst);
        }
    }

    dout(10) << __func__ << " h " << *h << " on " << file->fnode << dendl;
    return 0;
}
```

BlueFS使用扁平的双层目录结构，打开过程简单没有路径解析：
* 首先使用`dirname`从`dirmap`找到相应的`dir`。
* 从`dir`中找到对应文件的`FileRef`。
* 按读写方式进行初始化。

### Read File

```cpp
int64_t BlueFS::_read(FileReader *h,       ///< [in] read from here
                      uint64_t off,        ///< [in] offset
                      size_t len,          ///< [in] this many bytes
                      bufferlist *outbl,   ///< [out] optional: reference the result here
                      char *out)           ///< [out] optional: or copy it here
{
    FileReaderBuffer *buf = &(h->buf);

    bool prefetch = !outbl && !out;
    dout(10) << __func__ << " h " << h << " 0x" << std::hex << off << "~" << len << std::dec
             << " from " << h->file->fnode << (prefetch ? " prefetch" : "") << dendl;

    ++h->file->num_reading;

    if (!h->ignore_eof && off + len > h->file->fnode.size) {
        if (off > h->file->fnode.size)
            len = 0;
        else
            len = h->file->fnode.size - off;
        dout(20) << __func__ << " reaching (or past) eof, len clipped to 0x" << std::hex << len
                 << std::dec << dendl;
    }
    logger->inc(l_bluefs_read_count, 1);
    logger->inc(l_bluefs_read_bytes, len);
    if (prefetch) {
        logger->inc(l_bluefs_read_prefetch_count, 1);
        logger->inc(l_bluefs_read_prefetch_bytes, len);
    }

    if (outbl)
        outbl->clear();

    int64_t ret = 0;
    std::shared_lock s_lock(h->lock);
    while (len > 0) {
        size_t left;
        if (off < buf->bl_off || off >= buf->get_buf_end()) {
            s_lock.unlock();
            std::unique_lock u_lock(h->lock);
            buf->bl.reassign_to_mempool(mempool::mempool_bluefs_file_reader);
            if (off < buf->bl_off || off >= buf->get_buf_end()) {
                // if precondition hasn't changed during locking upgrade.
                buf->bl.clear();
                buf->bl_off = off & super.block_mask();
                uint64_t x_off = 0;
                auto p = h->file->fnode.seek(buf->bl_off, &x_off);
                if (p == h->file->fnode.extents.end()) {
                    dout(5) << __func__ << " reading less then required " << ret << "<" << ret + len
                            << dendl;
                    break;
                }

                uint64_t want = round_up_to(len + (off & ~super.block_mask()), super.block_size);
                want = std::max(want, buf->max_prefetch);
                uint64_t l = std::min(p->length - x_off, want);
                // hard cap to 1GB
                l = std::min(l, uint64_t(1) << 30);
                uint64_t eof_offset = round_up_to(h->file->fnode.size, super.block_size);
                if (!h->ignore_eof && buf->bl_off + l > eof_offset) {
                    l = eof_offset - buf->bl_off;
                }
                dout(20) << __func__ << " fetching 0x" << std::hex << x_off << "~" << l << std::dec
                         << " of " << *p << dendl;
                int r;
                // when reading BlueFS log (only happens on startup) use non-buffered io
                // it makes it in sync with logic in _flush_range()
                bool use_buffered_io =
                    h->file->fnode.ino == 1 ? false : cct->_conf->bluefs_buffered_io;
                if (!cct->_conf->bluefs_check_for_zeros) {
                    r = bdev[p->bdev]->read(
                        p->offset + x_off, l, &buf->bl, ioc[p->bdev], use_buffered_io);
                } else {
                    r = read(
                        p->bdev, p->offset + x_off, l, &buf->bl, ioc[p->bdev], use_buffered_io);
                }
                ceph_assert(r == 0);
            }
            u_lock.unlock();
            s_lock.lock();
            // we should recheck if buffer is valid after lock downgrade
            continue;
        }
        left = buf->get_buf_remaining(off);
        dout(20) << __func__ << " left 0x" << std::hex << left << " len 0x" << len << std::dec
                 << dendl;

        int64_t r = std::min(len, left);
        if (outbl) {
            bufferlist t;
            t.substr_of(buf->bl, off - buf->bl_off, r);
            outbl->claim_append(t);
        }
        if (out) {
            auto p = buf->bl.begin();
            p.seek(off - buf->bl_off);
            p.copy(r, out);
            out += r;
        }

        dout(30) << __func__ << " result chunk (0x" << std::hex << r << std::dec << " bytes):\n";
        bufferlist t;
        t.substr_of(buf->bl, off - buf->bl_off, r);
        t.hexdump(*_dout);
        *_dout << dendl;

        off += r;
        len -= r;
        ret += r;
        buf->pos += r;
    }

    dout(20) << __func__ << " got " << ret << dendl;
    ceph_assert(!outbl || (int)outbl->length() == ret);
    --h->file->num_reading;
    return ret;
}
```

### Write File

BlueFS只提供append操作，所有文件都是追加写入。RocksDB调用完append以后，数据并未真正落盘，而是先缓存在内存当中，只有调用`sync`时才会真正落盘。

```cpp
class FileWriter {
    // note: BlueRocksEnv uses this append exclusively, so it's safe
    // to use buffer_appender exclusively here (e.g., it's notion of
    // offset will remain accurate).
    void append(const char *buf, size_t len) {
        uint64_t l0 = get_buffer_length();
        ceph_assert(l0 + len <= std::numeric_limits<unsigned>::max());
        buffer_appender.append(buf, len);
    }
};
```

```cpp
int BlueFS::_flush(FileWriter *h, bool force, bool *flushed) {
    uint64_t length = h->get_buffer_length();
    uint64_t offset = h->pos;
    if (flushed) {
        *flushed = false;
    }
    if (!force && length < cct->_conf->bluefs_min_flush_size) {
        dout(10) << __func__ << " " << h << " ignoring, length " << length << " < min_flush_size "
                 << cct->_conf->bluefs_min_flush_size << dendl;
        return 0;
    }
    if (length == 0) {
        dout(10) << __func__ << " " << h << " no dirty data on " << h->file->fnode << dendl;
        return 0;
    }
    dout(10) << __func__ << " " << h << " 0x" << std::hex << offset << "~" << length << std::dec
             << " to " << h->file->fnode << dendl;
    ceph_assert(h->pos <= h->file->fnode.size);
    int r = _flush_range(h, offset, length);
    if (flushed) {
        *flushed = true;
    }
    return r;
}
```

```cpp
int BlueFS::_flush_range(FileWriter *h, uint64_t offset, uint64_t length) {
    dout(10) << __func__ << " " << h << " pos 0x" << std::hex << h->pos << " 0x" << offset << "~"
             << length << std::dec << " to " << h->file->fnode << dendl;
    if (h->file->deleted) {
        dout(10) << __func__ << "  deleted, no-op" << dendl;
        return 0;
    }

    ceph_assert(h->file->num_readers.load() == 0);

    bool buffered;
    if (h->file->fnode.ino == 1)
        buffered = false;
    else
        buffered = cct->_conf->bluefs_buffered_io;

    if (offset + length <= h->pos)
        return 0;
    if (offset < h->pos) {
        length -= h->pos - offset;
        offset = h->pos;
        dout(10) << " still need 0x" << std::hex << offset << "~" << length << std::dec << dendl;
    }
    ceph_assert(offset <= h->file->fnode.size);

    uint64_t allocated = h->file->fnode.get_allocated();
    vselector->sub_usage(h->file->vselector_hint, h->file->fnode);
    // do not bother to dirty the file if we are overwriting
    // previously allocated extents.

    if (allocated < offset + length) {
        // we should never run out of log space here; see the min runway check
        // in _flush_and_sync_log.
        ceph_assert(h->file->fnode.ino != 1);
        int r = _allocate(vselector->select_prefer_bdev(h->file->vselector_hint),
                          offset + length - allocated,
                          &h->file->fnode);
        if (r < 0) {
            derr << __func__ << " allocated: 0x" << std::hex << allocated << " offset: 0x" << offset
                 << " length: 0x" << length << std::dec << dendl;
            vselector->add_usage(h->file->vselector_hint, h->file->fnode);   // undo
            ceph_abort_msg("bluefs enospc");
            return r;
        }
        h->file->is_dirty = true;
    }
    if (h->file->fnode.size < offset + length) {
        h->file->fnode.size = offset + length;
        if (h->file->fnode.ino > 1) {
            // we do not need to dirty the log file (or it's compacting
            // replacement) when the file size changes because replay is
            // smart enough to discover it on its own.
            h->file->is_dirty = true;
        }
    }
    dout(20) << __func__ << " file now, unflushed " << h->file->fnode << dendl;

    uint64_t x_off = 0;
    auto p = h->file->fnode.seek(offset, &x_off);
    ceph_assert(p != h->file->fnode.extents.end());
    dout(20) << __func__ << " in " << *p << " x_off 0x" << std::hex << x_off << std::dec << dendl;

    unsigned partial = x_off & ~super.block_mask();
    if (partial) {
        dout(20) << __func__ << " using partial tail 0x" << std::hex << partial << std::dec
                 << dendl;
        x_off -= partial;
        offset -= partial;
        length += partial;
        dout(20) << __func__ << " waiting for previous aio to complete" << dendl;
        for (auto p : h->iocv) {
            if (p) {
                p->aio_wait();
            }
        }
    }

    auto bl = h->flush_buffer(cct, partial, length, super);
    ceph_assert(bl.length() >= length);
    h->pos = offset + length;
    length = bl.length();

    switch (h->writer_type) {
    case WRITER_WAL:
        logger->inc(l_bluefs_bytes_written_wal, length);
        break;
    case WRITER_SST:
        logger->inc(l_bluefs_bytes_written_sst, length);
        break;
    }

    dout(30) << "dump:\n";
    bl.hexdump(*_dout);
    *_dout << dendl;

    uint64_t bloff = 0;
    uint64_t bytes_written_slow = 0;
    while (length > 0) {
        uint64_t x_len = std::min(p->length - x_off, length);
        bufferlist t;
        t.substr_of(bl, bloff, x_len);
        if (cct->_conf->bluefs_sync_write) {
            bdev[p->bdev]->write(p->offset + x_off, t, buffered, h->write_hint);
        } else {
            bdev[p->bdev]->aio_write(
                p->offset + x_off, t, h->iocv[p->bdev], buffered, h->write_hint);
        }
        h->dirty_devs[p->bdev] = true;
        if (p->bdev == BDEV_SLOW) {
            bytes_written_slow += t.length();
        }

        bloff += x_len;
        length -= x_len;
        ++p;
        x_off = 0;
    }
    if (bytes_written_slow) {
        logger->inc(l_bluefs_bytes_written_slow, bytes_written_slow);
    }
    for (unsigned i = 0; i < MAX_BDEV; ++i) {
        if (bdev[i]) {
            if (h->iocv[i] && h->iocv[i]->has_pending_aios()) {
                bdev[i]->aio_submit(h->iocv[i]);
            }
        }
    }
    vselector->add_usage(h->file->vselector_hint, h->file->fnode);
    dout(20) << __func__ << " h " << h << " pos now 0x" << std::hex << h->pos << std::dec << dendl;
    return 0;
}
```

```cpp
int BlueFS::_flush_and_sync_log(std::unique_lock<ceph::mutex> &l,
                                uint64_t want_seq,
                                uint64_t jump_to) {
    while (log_flushing) {
        dout(10) << __func__ << " want_seq " << want_seq << " log is currently flushing, waiting"
                 << dendl;
        ceph_assert(!jump_to);
        log_cond.wait(l);
    }
    if (want_seq && want_seq <= log_seq_stable) {
        dout(10) << __func__ << " want_seq " << want_seq << " <= log_seq_stable " << log_seq_stable
                 << ", done" << dendl;
        ceph_assert(!jump_to);
        return 0;
    }
    if (log_t.empty() && dirty_files.empty()) {
        dout(10) << __func__ << " want_seq " << want_seq << " " << log_t
                 << " not dirty, dirty_files empty, no-op" << dendl;
        ceph_assert(!jump_to);
        return 0;
    }

    vector<interval_set<uint64_t>> to_release(pending_release.size());
    to_release.swap(pending_release);

    uint64_t seq = log_t.seq = ++log_seq;
    ceph_assert(want_seq == 0 || want_seq <= seq);
    log_t.uuid = super.uuid;

    // log dirty files
    auto lsi = dirty_files.find(seq);
    if (lsi != dirty_files.end()) {
        dout(20) << __func__ << " " << lsi->second.size() << " dirty_files" << dendl;
        for (auto &f : lsi->second) {
            dout(20) << __func__ << "   op_file_update " << f.fnode << dendl;
            log_t.op_file_update(f.fnode);
        }
    }

    dout(10) << __func__ << " " << log_t << dendl;
    ceph_assert(!log_t.empty());

    // allocate some more space (before we run out)?
    // BTW: this triggers `flush()` in the `page_aligned_appender` of `log_writer`.
    int64_t runway =
        log_writer->file->fnode.get_allocated() - log_writer->get_effective_write_pos();
    bool just_expanded_log = false;
    if (runway < (int64_t)cct->_conf->bluefs_min_log_runway) {
        dout(10) << __func__ << " allocating more log runway (0x" << std::hex << runway << std::dec
                 << " remaining)" << dendl;
        while (new_log_writer) {
            dout(10) << __func__ << " waiting for async compaction" << dendl;
            log_cond.wait(l);
        }
        vselector->sub_usage(log_writer->file->vselector_hint, log_writer->file->fnode);
        int r = _allocate(vselector->select_prefer_bdev(log_writer->file->vselector_hint),
                          cct->_conf->bluefs_max_log_runway,
                          &log_writer->file->fnode);
        ceph_assert(r == 0);
        vselector->add_usage(log_writer->file->vselector_hint, log_writer->file->fnode);
        log_t.op_file_update(log_writer->file->fnode);
        just_expanded_log = true;
    }

    bufferlist bl;
    bl.reserve(super.block_size);
    encode(log_t, bl);
    // pad to block boundary
    size_t realign = super.block_size - (bl.length() % super.block_size);
    if (realign && realign != super.block_size)
        bl.append_zero(realign);

    logger->inc(l_bluefs_logged_bytes, bl.length());

    if (just_expanded_log) {
        ceph_assert(bl.length() <=
                    runway);   // if we write this, we will have an unrecoverable data loss
    }

    log_writer->append(bl);

    log_t.clear();
    log_t.seq = 0;   // just so debug output is less confusing
    log_flushing = true;

    int r = _flush(log_writer, true);
    ceph_assert(r == 0);

    if (jump_to) {
        dout(10) << __func__ << " jumping log offset from 0x" << std::hex << log_writer->pos
                 << " -> 0x" << jump_to << std::dec << dendl;
        log_writer->pos = jump_to;
        vselector->sub_usage(log_writer->file->vselector_hint, log_writer->file->fnode.size);
        log_writer->file->fnode.size = jump_to;
        vselector->add_usage(log_writer->file->vselector_hint, log_writer->file->fnode.size);
    }

    _flush_bdev_safely(log_writer);

    log_flushing = false;
    log_cond.notify_all();

    // clean dirty files
    if (seq > log_seq_stable) {
        log_seq_stable = seq;
        dout(20) << __func__ << " log_seq_stable " << log_seq_stable << dendl;

        auto p = dirty_files.begin();
        while (p != dirty_files.end()) {
            if (p->first > log_seq_stable) {
                dout(20) << __func__ << " done cleaning up dirty files" << dendl;
                break;
            }

            auto l = p->second.begin();
            while (l != p->second.end()) {
                File *file = &*l;
                ceph_assert(file->dirty_seq > 0);
                ceph_assert(file->dirty_seq <= log_seq_stable);
                dout(20) << __func__ << " cleaned file " << file->fnode << dendl;
                file->dirty_seq = 0;
                p->second.erase(l++);
            }

            ceph_assert(p->second.empty());
            dirty_files.erase(p++);
        }
    } else {
        dout(20) << __func__ << " log_seq_stable " << log_seq_stable << " already >= out seq "
                 << seq << ", we lost a race against another log flush, done" << dendl;
    }

    for (unsigned i = 0; i < to_release.size(); ++i) {
        if (!to_release[i].empty()) {
            /* OK, now we have the guarantee alloc[i] won't be null. */
            int r = 0;
            if (cct->_conf->bdev_enable_discard && cct->_conf->bdev_async_discard) {
                r = bdev[i]->queue_discard(to_release[i]);
                if (r == 0)
                    continue;
            } else if (cct->_conf->bdev_enable_discard) {
                for (auto p = to_release[i].begin(); p != to_release[i].end(); ++p) {
                    bdev[i]->discard(p.get_start(), p.get_len());
                }
            }
            alloc[i]->release(to_release[i]);
            if (is_shared_alloc(i)) {
                shared_alloc->bluefs_used -= to_release[i].size();
            }
        }
    }

    _update_logger_stats();

    return 0;
}
```

写入流程：
* open file for write - 打开文件句柄，如果文件不存在则创建新的文件，如果文件存在则会更新文件fnode中的mtime，在事务log_t中添加更新操作，此时事务记录还不会持久化到journal中。
* append file - 将数据追加到文件当中，此时数据缓存在内存当中，并未落盘，也未分配新的空间。
* flush data(写数据) - 判断文件已分配剩余空间（fnode中的 allocated - size）是否足够写入缓存数据，若不够则为文件分配新的空间；如果有新分配空间，将文件标记为dirty加到dirty_files当中，将数据进行磁盘块大小对其后落盘，此时数据已经写到硬盘当中，元数据还未更新，同时BlueFS中的文件都是追加写入，不存在原地覆盖写，就算失败也不会污染原来的数据。
* flush metadata - 从dirty_files中取到dirty的文件，在事务log_t中添加更新操作（即添加OP_FILE_UPDATE类型的记录），将log_t中的内容sync到journal中，然后移除dirty_files中已更新的文件。

## Alloactor

### Introduction

BlueStore的磁盘分配器，负责高效的分配磁盘空间。目前支持Stupid和Bitmap两种磁盘分配器。都是仅仅在内存中分配，并不做持久化。

FreeListManager负责管理空闲空间列表。目前支持Extent和Bitmap两种，由于Extent开销大，新版中已经移除，只剩Bitmap。FreelistManager将block按一定数量组成段，每个段对应一个k/v键值对，key为第一个block在磁盘物理地址空间的offset，value为段内每个block的状态，即由0/1组成的位图，1为空闲，0为使用，这样可以通过与1进行异或运算，将分配和回收空间两种操作统一起来。

新版本BitMap分配器以Tree-Like的方式组织数据结构，整体分为L0、L1、L2三层。每一层都包含了完整的磁盘空间映射，只不过是slot以及children的粒度不同，这样可以加快查找。

![F2](./F2.png)

![F3](./F3.png)

分配器分配空间的大体策略如下：
* 循环从L2中找到可以分配空间的slot以及children位置。
* 在L2的slot以及children位置的基础上循环找到L1中可以分配空间的slot以及children位置。
* 在L1的slot以及children位置的基础上循环找到L0中可以分配空间的slot以及children位置。
* 在1-3步骤中保存分配空间的结果以及设置每层对应位置分配的标志位。

新版本Bitmap分配器整体架构设计有以下几点优势：
* Allocator避免在内存中使用指针和树形结构，使用`vector`连续的内存空间。
* Allocator充分利用64位机器CPU缓存的特性，最大程序的提高性能。
* Allocator操作的单元是64 bit，而不是在单个bit上操作。
* Allocator使用3级树状结构，可以更快的查找空闲空间。
* Allocator在初始化时L0、L1、L2三级BitMap就占用了固定的内存大小。
* Allocator可以支持并发的分配空闲，锁定L2的children(bit)即可，暂未实现。

空闲的空间列表会持久化在RocksDB中，为了保证元数据和数据写入的一致性，`BitmapFreeListmanager`会由使用者调用，会将对象元数据和分配结果通过RocksDB的`WriteBatch`接口原子写入。

### Concepts

* `extent` - offset + length，表示一段连续的物理磁盘地址空间。
* `PExtentVector` - 存放空间分配结果，可能是一个或者多个extent。
* `bdev_block_size` - 磁盘块大小，IO的最小单元，默认4K。
* `min_alloc_size` - 最小分配单元，SSD默认16K，HDD默认64K。
* `max_alloc_size` - 最大分配单元，默认0不限制，即一次连续的分配结果只包含一个extent。
* `alloc_unit` - 分配单元(AU)，一般设置为min_alloc_size。
* `slot` - uint64类型，64 bit，位操作的基本单元。
* `children` - slot的分配单元，可能占1 bit，也可能占2 bit。
* `slot_set` - 8个slot构成一个slot集合(512bit)，构成上层Level的 children。
* `slot_vector` - slot数组，也即uint64的数组。每一层都用一个slot_vector组织。

`Allocator`接口。

```cpp
class Allocator {
  /*
  * returns allocator type name as per names in config
  */
  virtual const char* get_type() const = 0;

  /*
   * Allocate required number of blocks in n number of extents.
   * Min and Max number of extents are limited by:
   * a. alloc unit
   * b. max_alloc_size.
   * as no extent can be lesser than block_size and greater than max_alloc size.
   * Apart from that extents can vary between these lower and higher limits according
   * to free block search algorithm and availability of contiguous space.
   */
  virtual int64_t allocate(uint64_t want_size, uint64_t block_size,
  	   uint64_t max_alloc_size, int64_t hint,
  	   PExtentVector *extents) = 0;

  /* Bulk release. Implementations may override this method to handle the whole
   * set at once. This could save e.g. unnecessary mutex dance. */
  virtual void release(const interval_set<uint64_t>& release_set) = 0;
  void release(const PExtentVector& release_set);

  virtual void dump() = 0;
  virtual void dump(std::function<void(uint64_t offset, uint64_t length)> notify) = 0;

  virtual void zoned_set_zone_states(std::vector<zone_state_t> &&_zone_states) {}
  virtual bool zoned_get_zones_to_clean(std::deque<uint64_t> *zones_to_clean) {
    return false;
  }

  virtual void init_add_free(uint64_t offset, uint64_t length) = 0;
  virtual void init_rm_free(uint64_t offset, uint64_t length) = 0;

  virtual uint64_t get_free() = 0;
  virtual double get_fragmentation()
  {
    return 0.0;
  }
  virtual double get_fragmentation_score();
  virtual void shutdown() = 0;
};
```

`AllocatorLevel`基类。

```cpp
class AllocatorLevel {
   protected:
    // 一个 slot 有多少个 children。slot 的大小是 64bit。
    // L0、L2的 children 大小是1bit，所以含有64个。
    // L1的 children 大小是2bit，所以含有32个。
    virtual uint64_t _children_per_slot() const = 0;

    // 每个 children 之间的磁盘空间长度，也即每个 children 的大小。
    // L0 的每个 children 间隔长度为：l0_granularity = alloc_unit。
    // L1 的每个 children 间隔长度为：l1_granularity = 512 * l0_granularity。
    // L2 的每个 children 间隔长度为：l2_granularity = 256 * l1_granularity。
    virtual uint64_t _level_granularity() const = 0;

   public:
    // L0 分配的次数，调用_allocate_l0的次数。
    static uint64_t l0_dives;

    // 遍历 L0 slot 的次数。
    static uint64_t l0_iterations;

    // 遍历 L0 slot(部分占用，部分空闲)的次数。
    static uint64_t l0_inner_iterations;

    // L0 分配 slot 的次数。
    static uint64_t alloc_fragments;

    // L1 分配 slot(部分占用，部分空闲)的次数。
    static uint64_t alloc_fragments_fast;

    // L2 分配的次数 ，调用 _allocate_l2的次数。
    static uint64_t l2_allocs;

    virtual ~AllocatorLevel() {}
};
```

### Allocate

![F4](./F4.png)

最终分配的结果存储在`interval_vector_t`结构体里面，实际上就是`extent_vector`，因为分配的磁盘空间不一定是完全连续的，所以会有多个extent，而在往`extent_vector`插入extent的时候会合并相邻的extent为一个extent。如果`max_alloc_size`设置了，且单个连续的分配大小超过了`max_alloc_size`，那么extent的length最大为`max_alloc_size`，同时这次分配结果也会拆分会多个extent。

### Release

```cpp
// to provide compatibility with BlueStore's allocator interface
void _free_l2(const interval_set<uint64_t> &rr) {
    uint64_t released = 0;
    std::lock_guard l(lock);
    for (auto r : rr) {
        released += l1._free_l1(r.first, r.second);
        uint64_t l2_pos = r.first / l2_granularity;
        uint64_t l2_pos_end =
            p2roundup(int64_t(r.first + r.second), int64_t(l2_granularity)) / l2_granularity;

        _mark_l2_free(l2_pos, l2_pos_end);
    }
    available += released;
}

uint64_t _free_l1(uint64_t offs, uint64_t len) {
    uint64_t l0_pos_start = offs / l0_granularity;
    uint64_t l0_pos_end = p2roundup(offs + len, l0_granularity) / l0_granularity;
    _mark_free_l1_l0(l0_pos_start, l0_pos_end);
    return l0_granularity * (l0_pos_end - l0_pos_start);
}

void _mark_free_l1_l0(int64_t l0_pos_start, int64_t l0_pos_end) {
    _mark_free_l0(l0_pos_start, l0_pos_end);
    l0_pos_start = p2align(l0_pos_start, int64_t(bits_per_slotset));
    l0_pos_end = p2roundup(l0_pos_end, int64_t(bits_per_slotset));
    _mark_l1_on_l0(l0_pos_start, l0_pos_end);
}

void _mark_free_l0(int64_t l0_pos_start, int64_t l0_pos_end) {
    auto d0 = L0_ENTRIES_PER_SLOT;

    auto pos = l0_pos_start;
    slot_t bits = (slot_t)1 << (l0_pos_start % d0);
    slot_t *val_s = &l0[pos / d0];
    int64_t pos_e = std::min(l0_pos_end, p2roundup<int64_t>(l0_pos_start + 1, d0));
    while (pos < pos_e) {
        *val_s |= bits;
        bits <<= 1;
        pos++;
    }
    pos_e = std::min(l0_pos_end, p2align<int64_t>(l0_pos_end, d0));
    while (pos < pos_e) {
        *(++val_s) = all_slot_set;
        pos += d0;
    }
    bits = 1;
    ++val_s;
    while (pos < l0_pos_end) {
        *val_s |= bits;
        bits <<= 1;
        pos++;
    }
}
```

## Block Device

![F5](./F5.png)

Ceph新的存储引擎BlueStore已成为默认的存储引擎，抛弃了对传统文件系统的依赖，直接管理裸设备，通过libaio的方式进行读写。抽象出了`BlockDevice`基类，提供统一的操作接口，后端对应不同的设备类型的实现(Kernel、NVME、NVRAM)等。

目前线上环境大多数还是使用HDD和Sata SSD，其派生的类为`KernelDevice`。

```cpp
class KernelDevice : public BlockDevice {
    // 裸设备以direct、buffered两种方式打开的fd
    int fd_direct, fd_buffered;

    // 设备总大小
    uint64_t size;

    // 块大小
    uint64_t block_size;

    // 设备路径
    std::string path;

    // 是否启用Libaio
    bool aio, dio;

    // interval_set是offset+length
    // discard_queued 存放需要做Discard的Extent。
    interval_set<uint64_t> discard_queued;

    // discard_finishing 和 discard_queued 交换值，存放完成Discard的Extent
    interval_set<uint64_t> discard_finishing;

    // libaio线程，收割完成的事件
    struct AioCompletionThread : public Thread {
        KernelDevice *bdev;
        explicit AioCompletionThread(KernelDevice *b) : bdev(b) {}
        void *entry() override {
            bdev->_aio_thread();
            return NULL;
        }
    } aio_thread;

    // Discard线程，用于SSD的Trim
    struct DiscardThread : public Thread {
        KernelDevice *bdev;
        explicit DiscardThread(KernelDevice *b) : bdev(b) {}
        void *entry() override {
            bdev->_discard_thread();
            return NULL;
        }
    } discard_thread;

    // 同步IO
    int read(uint64_t off, uint64_t len, bufferlist *pbl, IOContext *ioc,
             bool buffered) override;
    int write(uint64_t off, bufferlist &bl, bool buffered) override;

    // 异步IO
    int aio_read(uint64_t off, uint64_t len, bufferlist *pbl,
                 IOContext *ioc) override;
    int aio_read(uint64_t off, uint64_t len, bufferlist *pbl,
                 IOContext *ioc) override;
    void aio_submit(IOContext *ioc) override;

    // sync数据
    int flush() override;

    // 对SSD指定offset、len的数据做Trim
    int discard(uint64_t offset, uint64_t len) override;
};
```

### Initial

BlueFS会使用BlockDevice存放RocksDB的WAL以及SStable，同样BlueStore也会使用BlockDevice来存放对象的数据。创建的时候根据不同的设备类型然后创建不同的设备。

```cpp
BlockDevice *BlockDevice::create(CephContext *cct,
                                 const string &path,
                                 aio_callback_t cb,
                                 void *cbpriv,
                                 aio_callback_t d_cb,
                                 void *d_cbpriv) {
    const string blk_dev_name = cct->_conf.get_val<string>("bdev_type");
    block_device_t device_type = block_device_t::unknown;
    if (blk_dev_name.empty()) {
        device_type = detect_device_type(path);
    } else {
        device_type = device_type_from_name(blk_dev_name);
    }
    return create_with_type(device_type, cct, path, cb, cbpriv, d_cb, d_cbpriv);
}
```



```cpp
int KernelDevice::open(const string &p) {
    path = p;
    int r = 0, i = 0;
    dout(1) << __func__ << " path " << path << dendl;

    for (i = 0; i < WRITE_LIFE_MAX; i++) {
        int fd = ::open(path.c_str(), O_RDWR | O_DIRECT);
        if (fd < 0) {
            r = -errno;
            break;
        }
        fd_directs[i] = fd;

        fd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            r = -errno;
            break;
        }
        fd_buffereds[i] = fd;
    }

    if (i != WRITE_LIFE_MAX) {
        derr << __func__ << " open got: " << cpp_strerror(r) << dendl;
        goto out_fail;
    }

#if defined(F_SET_FILE_RW_HINT)
    for (i = WRITE_LIFE_NONE; i < WRITE_LIFE_MAX; i++) {
        if (fcntl(fd_directs[i], F_SET_FILE_RW_HINT, &i) < 0) {
            r = -errno;
            break;
        }
        if (fcntl(fd_buffereds[i], F_SET_FILE_RW_HINT, &i) < 0) {
            r = -errno;
            break;
        }
    }
    if (i != WRITE_LIFE_MAX) {
        enable_wrt = false;
        dout(0) << "ioctl(F_SET_FILE_RW_HINT) on " << path << " failed: " << cpp_strerror(r)
                << dendl;
    }
#endif

    dio = true;
    aio = cct->_conf->bdev_aio;
    if (!aio) {
        ceph_abort_msg("non-aio not supported");
    }

    // disable readahead as it will wreak havoc on our mix of
    // directio/aio and buffered io.
    r = posix_fadvise(fd_buffereds[WRITE_LIFE_NOT_SET], 0, 0, POSIX_FADV_RANDOM);
    if (r) {
        r = -r;
        derr << __func__ << " posix_fadvise got: " << cpp_strerror(r) << dendl;
        goto out_fail;
    }

    if (lock_exclusive) {
        r = _lock();
        if (r < 0) {
            derr << __func__ << " failed to lock " << path << ": " << cpp_strerror(r) << dendl;
            goto out_fail;
        }
    }

    struct stat st;
    r = ::fstat(fd_directs[WRITE_LIFE_NOT_SET], &st);
    if (r < 0) {
        r = -errno;
        derr << __func__ << " fstat got " << cpp_strerror(r) << dendl;
        goto out_fail;
    }

    // Operate as though the block size is 4 KB.  The backing file
    // blksize doesn't strictly matter except that some file systems may
    // require a read/modify/write if we write something smaller than
    // it.
    block_size = cct->_conf->bdev_block_size;
    if (block_size != (unsigned)st.st_blksize) {
        dout(1) << __func__ << " backing device/file reports st_blksize " << st.st_blksize
                << ", using bdev_block_size " << block_size << " anyway" << dendl;
    }


    {
        BlkDev blkdev_direct(fd_directs[WRITE_LIFE_NOT_SET]);
        BlkDev blkdev_buffered(fd_buffereds[WRITE_LIFE_NOT_SET]);

        if (S_ISBLK(st.st_mode)) {
            int64_t s;
            r = blkdev_direct.get_size(&s);
            if (r < 0) {
                goto out_fail;
            }
            size = s;
        } else {
            size = st.st_size;
        }

        char partition[PATH_MAX], devname[PATH_MAX];
        if ((r = blkdev_buffered.partition(partition, PATH_MAX)) ||
            (r = blkdev_buffered.wholedisk(devname, PATH_MAX))) {
            derr << "unable to get device name for " << path << ": " << cpp_strerror(r) << dendl;
            rotational = true;
        } else {
            dout(20) << __func__ << " devname " << devname << dendl;
            rotational = blkdev_buffered.is_rotational();
            support_discard = blkdev_buffered.support_discard();
            this->devname = devname;
            _detect_vdo();
        }
    }

    r = _aio_start();
    if (r < 0) {
        goto out_fail;
    }
    _discard_start();

    // round size down to an even block
    size &= ~(block_size - 1);

    dout(1) << __func__ << " size " << size << " (0x" << std::hex << size << std::dec << ", "
            << byte_u_t(size) << ")"
            << " block_size " << block_size << " (" << byte_u_t(block_size) << ")"
            << " " << (rotational ? "rotational" : "non-rotational") << " discard "
            << (support_discard ? "supported" : "not supported") << dendl;
    return 0;

out_fail:
    for (i = 0; i < WRITE_LIFE_MAX; i++) {
        if (fd_directs[i] >= 0) {
            VOID_TEMP_FAILURE_RETRY(::close(fd_directs[i]));
            fd_directs[i] = -1;
        } else {
            break;
        }
        if (fd_buffereds[i] >= 0) {
            VOID_TEMP_FAILURE_RETRY(::close(fd_buffereds[i]));
            fd_buffereds[i] = -1;
        } else {
            break;
        }
    }
    return r;
}
```

此时设备以及可以进行IO；设备的空间管理以及使用由BlueFS和BlueStore决定，BlockDevice仅仅提供同步IO和异步IO的操作接口。

### Synchronous I/O

#### Read

```cpp
int KernelDevice::read(uint64_t off, uint64_t len, bufferlist *pbl, IOContext *ioc, bool buffered) {
    dout(5) << __func__ << " 0x" << std::hex << off << "~" << len << std::dec
            << (buffered ? " (buffered)" : " (direct)") << dendl;
    ceph_assert(is_valid_io(off, len));

    _aio_log_start(ioc, off, len);

    auto start1 = mono_clock::now();

    auto p = ceph::buffer::ptr_node::create(ceph::buffer::create_small_page_aligned(len));
    int r = ::pread(buffered ? fd_buffereds[WRITE_LIFE_NOT_SET] : fd_directs[WRITE_LIFE_NOT_SET],
                    p->c_str(),
                    len,
                    off);
    auto age = cct->_conf->bdev_debug_aio_log_age;
    if (mono_clock::now() - start1 >= make_timespan(age)) {
        derr << __func__ << " stalled read "
             << " 0x" << std::hex << off << "~" << len << std::dec
             << (buffered ? " (buffered)" : " (direct)") << " since " << start1 << ", timeout is "
             << age << "s" << dendl;
    }

    if (r < 0) {
        if (ioc->allow_eio && is_expected_ioerr(r)) {
            r = -EIO;
        } else {
            r = -errno;
        }
        goto out;
    }
    ceph_assert((uint64_t)r == len);
    pbl->push_back(std::move(p));

    dout(40) << "data: ";
    pbl->hexdump(*_dout);
    *_dout << dendl;

out:
    _aio_log_finish(ioc, off, len);
    return r < 0 ? r : 0;
}
```

#### Write

```cpp
int KernelDevice::_sync_write(uint64_t off, bufferlist &bl, bool buffered, int write_hint) {
    uint64_t len = bl.length();
    dout(5) << __func__ << " 0x" << std::hex << off << "~" << len << std::dec
            << (buffered ? " (buffered)" : " (direct)") << dendl;
    if (cct->_conf->bdev_inject_crash && rand() % cct->_conf->bdev_inject_crash == 0) {
        derr << __func__ << " bdev_inject_crash: dropping io 0x" << std::hex << off << "~" << len
             << std::dec << dendl;
        ++injecting_crash;
        return 0;
    }
    vector<iovec> iov;
    bl.prepare_iov(&iov);

    auto left = len;
    auto o = off;
    size_t idx = 0;
    do {
        auto r = ::pwritev(choose_fd(buffered, write_hint), &iov[idx], iov.size() - idx, o);

        if (r < 0) {
            r = -errno;
            derr << __func__ << " pwritev error: " << cpp_strerror(r) << dendl;
            return r;
        }
        o += r;
        left -= r;
        if (left) {
            // skip fully processed IOVs
            while (idx < iov.size() && (size_t)r >= iov[idx].iov_len) {
                r -= iov[idx++].iov_len;
            }
            // update partially processed one if any
            if (r) {
                ceph_assert(idx < iov.size());
                ceph_assert((size_t)r < iov[idx].iov_len);
                iov[idx].iov_base = static_cast<char *>(iov[idx].iov_base) + r;
                iov[idx].iov_len -= r;
                r = 0;
            }
            ceph_assert(r == 0);
        }
    } while (left);

#ifdef HAVE_SYNC_FILE_RANGE
    if (buffered) {
        // initiate IO and wait till it completes
        auto r = ::sync_file_range(
            fd_buffereds[WRITE_LIFE_NOT_SET],
            off,
            len,
            SYNC_FILE_RANGE_WRITE | SYNC_FILE_RANGE_WAIT_AFTER | SYNC_FILE_RANGE_WAIT_BEFORE);
        if (r < 0) {
            r = -errno;
            derr << __func__ << " sync_file_range error: " << cpp_strerror(r) << dendl;
            return r;
        }
    }
#endif

    io_since_flush.store(true);

    return 0;
}
```

### Asynchronous I/O

使用`libaio`进行异步数据读写。

*NOTE：当前似乎`io_uring`是个更好的选择。*

```cpp
void KernelDevice::aio_submit(IOContext *ioc) {
    dout(20) << __func__ << " ioc " << ioc << " pending " << ioc->num_pending.load() << " running "
             << ioc->num_running.load() << dendl;

    if (ioc->num_pending.load() == 0) {
        return;
    }

    // move these aside, and get our end iterator position now, as the
    // aios might complete as soon as they are submitted and queue more
    // wal aio's.
    list<aio_t>::iterator e = ioc->running_aios.begin();
    ioc->running_aios.splice(e, ioc->pending_aios);

    int pending = ioc->num_pending.load();
    ioc->num_running += pending;
    ioc->num_pending -= pending;
    ceph_assert(ioc->num_pending.load() == 0);   // we should be only thread doing this
    ceph_assert(ioc->pending_aios.size() == 0);

    if (cct->_conf->bdev_debug_aio) {
        list<aio_t>::iterator p = ioc->running_aios.begin();
        while (p != e) {
            dout(30) << __func__ << " " << *p << dendl;
            std::lock_guard l(debug_queue_lock);
            debug_aio_link(*p++);
        }
    }

    void *priv = static_cast<void *>(ioc);
    int r, retries = 0;
    // num of pending aios should not overflow when passed to submit_batch()
    assert(pending <= std::numeric_limits<uint16_t>::max());
    r = io_queue->submit_batch(ioc->running_aios.begin(), e, pending, priv, &retries);

    if (retries)
        derr << __func__ << " retries " << retries << dendl;
    if (r < 0) {
        derr << " aio submit got " << cpp_strerror(r) << dendl;
        ceph_assert(r == 0);
    }
}
```

在AIO 线程进行完成收割。

```cpp
void KernelDevice::_aio_thread() {
    dout(10) << __func__ << " start" << dendl;
    int inject_crash_count = 0;
    while (!aio_stop) {
        dout(40) << __func__ << " polling" << dendl;
        int max = cct->_conf->bdev_aio_reap_max;
        aio_t *aio[max];
        int r = io_queue->get_next_completed(cct->_conf->bdev_aio_poll_ms, aio, max);
        if (r < 0) {
            derr << __func__ << " got " << cpp_strerror(r) << dendl;
            ceph_abort_msg("got unexpected error from io_getevents");
        }
        if (r > 0) {
            dout(30) << __func__ << " got " << r << " completed aios" << dendl;
            for (int i = 0; i < r; ++i) {
                IOContext *ioc = static_cast<IOContext *>(aio[i]->priv);
                _aio_log_finish(ioc, aio[i]->offset, aio[i]->length);
                if (aio[i]->queue_item.is_linked()) {
                    std::lock_guard l(debug_queue_lock);
                    debug_aio_unlink(*aio[i]);
                }

                // set flag indicating new ios have completed.  we do this *before*
                // any completion or notifications so that any user flush() that
                // follows the observed io completion will include this io.  Note
                // that an earlier, racing flush() could observe and clear this
                // flag, but that also ensures that the IO will be stable before the
                // later flush() occurs.
                io_since_flush.store(true);

                long r = aio[i]->get_return_value();
                if (r < 0) {
                    derr << __func__ << " got r=" << r << " (" << cpp_strerror(r) << ")" << dendl;
                    if (ioc->allow_eio && is_expected_ioerr(r)) {
                        derr << __func__ << " translating the error to EIO for upper layer"
                             << dendl;
                        ioc->set_return_value(-EIO);
                    } else {
                        if (is_expected_ioerr(r)) {
                            note_io_error_event(devname.c_str(),
                                                path.c_str(),
                                                r,
#if defined(HAVE_POSIXAIO)
                                                aio[i]->aio.aiocb.aio_lio_opcode,
#else
                                                 aio[i]->iocb.aio_lio_opcode,
#endif
                                                aio[i]->offset,
                                                aio[i]->length);
                            ceph_abort_msg("Unexpected IO error. "
                                           "This may suggest a hardware issue. "
                                           "Please check your kernel log!");
                        }
                        ceph_abort_msg("Unexpected IO error. "
                                       "This may suggest HW issue. Please check your dmesg!");
                    }
                } else if (aio[i]->length != (uint64_t)r) {
                    derr << "aio to 0x" << std::hex << aio[i]->offset << "~" << aio[i]->length
                         << std::dec << " but returned: " << r << dendl;
                    ceph_abort_msg("unexpected aio return value: does not match length");
                }

                dout(10) << __func__ << " finished aio " << aio[i] << " r " << r << " ioc " << ioc
                         << " with " << (ioc->num_running.load() - 1) << " aios left" << dendl;

                // NOTE: once num_running and we either call the callback or
                // call aio_wake we cannot touch ioc or aio[] as the caller
                // may free it.
                if (ioc->priv) {
                    if (--ioc->num_running == 0) {
                        aio_callback(aio_callback_priv, ioc->priv);
                    }
                } else {
                    ioc->try_aio_wake();
                }
            }
        }
        if (cct->_conf->bdev_debug_aio) {
            utime_t now = ceph_clock_now();
            std::lock_guard l(debug_queue_lock);
            if (debug_oldest) {
                if (debug_stall_since == utime_t()) {
                    debug_stall_since = now;
                } else {
                    if (cct->_conf->bdev_debug_aio_suicide_timeout) {
                        utime_t cutoff = now;
                        cutoff -= cct->_conf->bdev_debug_aio_suicide_timeout;
                        if (debug_stall_since < cutoff) {
                            derr << __func__ << " stalled aio " << debug_oldest << " since "
                                 << debug_stall_since << ", timeout is "
                                 << cct->_conf->bdev_debug_aio_suicide_timeout << "s, suicide"
                                 << dendl;
                            ceph_abort_msg("stalled aio... buggy kernel or bad device?");
                        }
                    }
                }
            }
        }
        reap_ioc();
        if (cct->_conf->bdev_inject_crash) {
            ++inject_crash_count;
            if (inject_crash_count * cct->_conf->bdev_aio_poll_ms / 1000 >
                cct->_conf->bdev_inject_crash + cct->_conf->bdev_inject_crash_flush_delay) {
                derr << __func__ << " bdev_inject_crash trigger from aio thread" << dendl;
                cct->_log->flush();
                _exit(1);
            }
        }
    }
    reap_ioc();
    dout(10) << __func__ << " end" << dendl;
}
```

### Flush

BlueStore往往采用异步IO，同步数据到磁盘上调用flush函数。

先通过`libaio`写入数据，然后在`kv_sync_thread`里面调用flush函数，把数据和元数据同步到磁盘上。

```cpp
int KernelDevice::flush() {
    // protect flush with a mutex.  note that we are not really protecting
    // data here.  instead, we're ensuring that if any flush() caller
    // sees that io_since_flush is true, they block any racing callers
    // until the flush is observed.  that allows racing threads to be
    // calling flush while still ensuring that *any* of them that got an
    // aio completion notification will not return before that aio is
    // stable on disk: whichever thread sees the flag first will block
    // followers until the aio is stable.
    std::lock_guard l(flush_mutex);

    bool expect = true;
    if (!io_since_flush.compare_exchange_strong(expect, false)) {
        dout(10) << __func__ << " no-op (no ios since last flush), flag is "
                 << (int)io_since_flush.load() << dendl;
        return 0;
    }

    dout(10) << __func__ << " start" << dendl;
    if (cct->_conf->bdev_inject_crash) {
        ++injecting_crash;
        // sleep for a moment to give other threads a chance to submit or
        // wait on io that races with a flush.
        derr << __func__ << " injecting crash. first we sleep..." << dendl;
        sleep(cct->_conf->bdev_inject_crash_flush_delay);
        derr << __func__ << " and now we die" << dendl;
        cct->_log->flush();
        _exit(1);
    }
    utime_t start = ceph_clock_now();
    int r = ::fdatasync(fd_directs[WRITE_LIFE_NOT_SET]);
    utime_t end = ceph_clock_now();
    utime_t dur = end - start;
    if (r < 0) {
        r = -errno;
        derr << __func__ << " fdatasync got: " << cpp_strerror(r) << dendl;
        ceph_abort();
    }
    dout(5) << __func__ << " in " << dur << dendl;
    ;
    return r;
}
```


### Discard

BlueStore针对SSD的优化之一就是添加了Discard操作。Discard(Trim)的主要作用是提高GC效率以及减小写入放大。

KernelDevice会启动一个Discard线程，不断的从`discard_queued`里面取出Extent，然后做Discard。

```cpp
void KernelDevice::_discard_thread() {
    std::unique_lock l(discard_lock);
    ceph_assert(!discard_started);
    discard_started = true;
    discard_cond.notify_all();
    while (true) {
        ceph_assert(discard_finishing.empty());
        if (discard_queued.empty()) {
            if (discard_stop)
                break;
            dout(20) << __func__ << " sleep" << dendl;
            discard_cond.notify_all();   // for the thread trying to drain...
            discard_cond.wait(l);
            dout(20) << __func__ << " wake" << dendl;
        } else {
            discard_finishing.swap(discard_queued);
            discard_running = true;
            l.unlock();
            dout(20) << __func__ << " finishing" << dendl;
            for (auto p = discard_finishing.begin(); p != discard_finishing.end(); ++p) {
                discard(p.get_start(), p.get_len());
            }

            discard_callback(discard_callback_priv, static_cast<void *>(&discard_finishing));
            discard_finishing.clear();
            l.lock();
            discard_running = false;
        }
    }
    dout(10) << __func__ << " finish" << dendl;
    discard_started = false;
}
```

```cpp
int KernelDevice::discard(uint64_t offset, uint64_t len) {
    int r = 0;
    if (cct->_conf->objectstore_blackhole) {
        lderr(cct) << __func__ << " objectstore_blackhole=true, throwing out IO" << dendl;
        return 0;
    }
    if (support_discard) {
        dout(10) << __func__ << " 0x" << std::hex << offset << "~" << len << std::dec << dendl;

        r = BlkDev{fd_directs[WRITE_LIFE_NOT_SET]}.discard((int64_t)offset, (int64_t)len);
    }
    return r;
}
```

BlueFS和BlueStore在涉及到数据删除的时候调用`queue_discard`将需要做Discard的Extent传入`discard_queued`。

```cpp
int KernelDevice::queue_discard(interval_set<uint64_t> &to_release) {
    if (!support_discard)
        return -1;

    if (to_release.empty())
        return 0;

    std::lock_guard l(discard_lock);
    discard_queued.insert(to_release);
    discard_cond.notify_all();
    return 0;
}
```

---

See also: [SSD](/SSD/README.md)

## Cache

BlueStore抛弃了文件系统，直接管理裸设备，那么便用不了文件系统的Cache机制，需要自己实现元数据和数据的Cache，缓存系统的性能直接影响到了BlueStore的性能。

BlueStore有两种Cache算法：`LRU`和`2Q`。元数据使用`LRUCache`，数据使用`2QCache`。

## I/0 Operations

### Read Operations

处理读请求会先从RocksDB找到对应的磁盘空间，然后通过`BlockDevice`读出数据。

### Write Operations

处理写请求时会进入事物的状态机，简单流程就是先写数据，然后再原子的写入对象元数据和分配结果元数据。写入数据如果是对齐写入，则最终会调用`do_write_big`；如果是非对齐写，最终会调用`do_write_small`。