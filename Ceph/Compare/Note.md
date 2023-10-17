# Compare FileSystem with RBD

## Metadata Benchmark

### RBD-SSD

|Operation|Max IOPS|Min IOPS|Mean IOPS|Std Dev|
|-|-|-|-|-|
|Directory creation|54393.113|53621.789|54073.120|328.301|
|Directory stat|550228.860|522667.541|540535.299|12649.630|
|Directory removal|75918.079|73809.065|74995.775|881.067|
|File creation|83807.678|82703.402|83389.259|488.875|
|File stat|548966.300|547686.234|548179.785|562.147|
|File read|322602.549|313995.945|319416.130|3852.332|
|File removal|132483.871|120322.056|127663.853|5275.539|
|Tree creation|70992.475|51268.029|64264.657|9191.914|
|Tree removal|1009.915|879.343|953.008|54.607|

### Cephfs-SSD

|Operation|Max IOPS|Min IOPS|Mean IOPS|Std Dev|
|-|-|-|-|-|
|Directory creation|2553.072|541.368|1596.902|824.275|
|Directory stat|290651.067|283566.005|286550.577|2998.164|
|Directory removal|1861.537|910.250|1386.242|388.362|
|File creation|1354.966|453.008|980.843|383.929|
|File stat|293519.405|64141.747|216824.313|107963.265|
|File read|194388.035|105662.017|163947.731|41227.836|
|File removal|1036.628|439.879|815.414|266.944|
|Tree creation|3979.693|50.836|1444.149|1795.828|
|Tree removal|72.051|19.493|38.413|23.848|

### RBD-HDD

|Operation|Max IOPS|Min IOPS|Mean IOPS|Std Dev|
|-|-|-|-|-|
|Directory creation|54946.567|48018.617|52556.927|3210.577|
|Directory stat|572110.997|530379.733|557978.000|19516.826|
|Directory removal|77039.653|73372.283|75381.464|1517.629|
|File creation|84241.131|82831.660|83360.958|626.624|
|File stat|572411.878|517393.982|550593.790|23859.308|
|File read|325727.040|322658.260|323919.899|1310.860|
|File removal|130499.474|127394.620|128751.964|1297.228|
|Tree creation|74956.900|55290.367|67777.478|8862.724|
|Tree removal|1038.629|974.295|1015.120|28.978|

## Cephfs-HDD

|Operation|Max IOPS|Min IOPS|Mean IOPS|Std Dev|
|-|-|-|-|-|
|Directory creation|41306.462|18594.644|29069.639|9355.380|
|Directory stat|520992.788|458022.025|499954.701|29650.938|
|Directory removal|75063.173|71072.527|72485.699|1825.379|
|File creation|82851.930|64961.020|74042.812|7306.478|
|File stat|548477.366|536107.391|540841.180|5451.116|
|File read|323478.040|310822.326|318730.470|5629.310|
|File removal|128580.089|125653.010|127138.937|1195.395|
|Tree creation|71650.346|49502.500|57693.106|9918.747|
|Tree removal|970.285|949.553|959.311|8.507|

### Compare

**Directory creation:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|54073.120|100%|
|Cephfs-SSD|1596.902|2%|
|RBD-HDD|52556.927|97%|
|Cephfs-HDD|29069.639|53%|

**Directory stat:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|540535.299|100%|
|Cephfs-SSD|286550.577|53%|
|RBD-HDD|557978.000|100%|
|Cephfs-HDD|499954.701|92%|


**Directory removal:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|74995.775|100%|
|Cephfs-SSD|1386.242|1%|
|RBD-HDD|75381.464|100%|
|Cephfs-HDD|72485.699|96%|

**File creation:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|83389.259|100%|
|Cephfs-SSD|980.843|1%|
|RBD-HDD|83360.958|99%|
|Cephfs-HDD|74042.812|88%|

**File stat:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|548179.785|100%|
|Cephfs-SSD|216824.313|40%|
|RBD-HDD|550593.790|100%|
|Cephfs-HDD|540841.180|98%|

**File read:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|319416.130|100%|
|Cephfs-SSD|163947.731|51%|
|RBD-HDD|323919.899|100%|
|Cephfs-HDD|318730.470|99%|

**File removal:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|127663.853|100%|
|Cephfs-SSD|815.414|1%|
|RBD-HDD|128751.964|100%|
|Cephfs-HDD|127138.937|99%|

**Tree creation:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|64264.657|100%|
|Cephfs-SSD|1444.149|2%|
|RBD-HDD|67777.478|100%|
|Cephfs-HDD|57693.106|89%|

**Tree removal:**

|Name|IOPS|%|
|-|-|-|
|RBD-SSD|953.008|100%|
|Cephfs-SSD|38.413|4%|
|RBD-HDD|1015.120|100%|
|Cephfs-HDD|959.311|100%|

## Sequential Write

**1 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|1532|192MiB/s|
|Cephfs-SSD|141|17.7MiB/s|
|RBD-HDD|605|75.7MiB/s|
|Cephfs-HDD|896|112MiB/s|

**4 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|725|90.6MiB/s|
|Cephfs-SSD|413|51.7MiB/s|
|RBD-HDD|78|9.81MiB/s|
|Cephfs-HDD|468|58.6MiB/s|

**16 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|346|43.3MiB/s|
|Cephfs-SSD|1071|134MiB/s|
|RBD-HDD|90|11.3MiB/s|
|Cephfs-HDD|394|49.3MiB/s|

**64 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|196|24.6MiB/s|
|Cephfs-SSD|3284|411MiB/s|
|RBD-HDD|72|9332KiB/s|
|Cephfs-HDD|273|34.2MiB/s|

## Sequential Read

**1 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|195|24.4MiB/s|
|Cephfs-SSD|217|27.2MiB/s|
|RBD-HDD|107|13.4MiB/s|
|Cephfs-HDD|214|26.8MiB/s|

**4 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|660|82.5MiB/s|
|Cephfs-SSD|939|117MiB/s|
|RBD-HDD|505|63.2MiB/s|
|Cephfs-HDD|724|90.5MiB/s|

**16 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|1595|199MiB/s|
|Cephfs-SSD|2186|273MiB/s|
|RBD-HDD|1601|200MiB/s|
|Cephfs-HDD|1437|180MiB/s|

**64 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|3008|376MiB/s|
|Cephfs-SSD|2013|252MiB/s|
|RBD-HDD|2510|314MiB/s|
|Cephfs-HDD|1853|232MiB/s|

## Random Write

**1 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|1325|5302KiB/s|
|Cephfs-SSD|148|596KiB/s|
|RBD-HDD|585|2343KiB/s|
|Cephfs-HDD|1000|4002KiB/s|

**4 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|643|2575KiB/s|
|Cephfs-SSD|616|2465KiB/s|
|RBD-HDD|931|3726KiB/s|
|Cephfs-HDD|905|3621KiB/s|

**16 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|516|2066KiB/s|
|Cephfs-SSD|2005|8022KiB/s|
|RBD-HDD|704|2819KiB/s|
|Cephfs-HDD|596|2388KiB/s|

**64 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|324|1297KiB/s|
|Cephfs-SSD|5451|21.3MiB/s|
|RBD-HDD|373|1493KiB/s|
|Cephfs-HDD|298|1193KiB/s|

## Random Read

**1 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|190|763KiB/s|
|Cephfs-SSD|605|2421KiB/s|
|RBD-HDD|75|301KiB/s|
|Cephfs-HDD|195|782KiB/s|

**4 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|769|3077KiB/s|
|Cephfs-SSD|895|3583KiB/s|
|RBD-HDD|434|1739KiB/s|
|Cephfs-HDD|726|2904KiB/s|

**16 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|1715|6861KiB/s|
|Cephfs-SSD|5779|22.6MiB/s|
|RBD-HDD|1466|5867KiB/s|
|Cephfs-HDD|1608|6435KiB/s|

**64 Threads:**

|Name|IOPS|Bandwidth|
|-|-|-|
|RBD-SSD|4416|17.3MiB/s|
|Cephfs-SSD|8246|32.2MiB/s|
|RBD-HDD|5369|20.0MiB/s|
|Cephfs-HDD|5437|21.2MiB/s|

## Summary

* 对于顺序写负载，Cephfs适用于并发写入场景，RBD适用于小并发场景（Cephfs-HDD是个另外，表现得比较像RBD）。
* 对于顺序读负载，几种类型的测试结果都差不多。
* 对于随机写负载，Cephfs适用于并发写入场景，RBD适用于小并发场景。
* 对于随机读负载，RBD更适用于小并发场景，在大并发下，几乎无区别。

解释：
* RBD存在本地缓存，即使是`O_DIRECT` IO操作也只走到缓存就终止了，这导致RBD在低并发下优于Cephfs。
* 当并发量提升时，RBD逐渐遇到瓶颈（只有一个OSD可供写入），并最终导致串行的修改，而Cephfs可以同时写入多个OSD，以达到负载均衡和并行写入的效果，最终的结果变成了，Cephfs优于RBD。

## Original Data

|Name|URL|
|-|-|
|RBD-SSD|[RBD-SSD](./rbd_ssd_out.log)|
|RBD-HDD|[RBD-HDD](./rbd_hdd_out.log)|
|Cephfs-SSD|[Cephfs-SSD](./cephfs_ssd_out.log)|
|Cephfs-HDD|[Cephfs-HDD](./cephfs_hdd_out.log)|

## Benchmark Script

```sh
#!/bin/bash

function fio_test()
{
    TEST_PATH="${1}/test"
    THREADS=$2

    echo "Testing SWrite on ${TEST_PATH} with threads ${THREADS}"

    rm -f $TEST_PATH

    fio -filename=${TEST_PATH} \
        -ioengine=psync \
        -rw=write \
        -bs=128k \
        -direct=1 \
        -group_reporting=1 \
        -fallocate=none \
        -name="SWRITE ${TEST_PATH}" \
        -numjobs=${THREADS} \
        -nrfiles=1 \
        -runtime=60 \
        -size=1G

    echo "Testing SRead on ${TEST_PATH} with threads ${THREADS}"

    fio -filename=${TEST_PATH} \
        -ioengine=psync \
        -rw=read \
        -bs=128k \
        -direct=1 \
        -group_reporting=1 \
        -fallocate=none \
        -time_based=1 \
        -name="SREAD ${TEST_PATH}" \
        -numjobs=${THREADS} \
        -nrfiles=1 \
        -runtime=60 \
        -size=1G

    rm -f $TEST_PATH

    echo "Testing RWrite on ${TEST_PATH} with threads ${THREADS}"

    fio -filename=${TEST_PATH} \
        -ioengine=psync \
        -rw=randwrite \
        -bs=4k \
        -direct=1 \
        -group_reporting=1 \
        -fallocate=none \
        -time_based=1 \
        -name="RWrite ${TEST_PATH}" \
        -numjobs=${THREADS} \
        -nrfiles=1 \
        -runtime=60 \
        -size=1G

    echo "Testing RRead on ${TEST_PATH} with threads ${THREADS}"

    fio -filename=${TEST_PATH} \
        -ioengine=psync \
        -rw=randread \
        -bs=4k \
        -direct=1 \
        -group_reporting=1 \
        -fallocate=none \
        -time_based=1 \
        -name="RREAD ${TEST_PATH}" \
        -numjobs=${THREADS} \
        -nrfiles=1 \
        -runtime=60 \
        -size=1G
}

function md_test()
{
    echo "Testing metadata on ${1}/mdtest_dir"
    mdtest -n 5000 -u -z 2 -i 3 -d $1
}

if test $# -lt 1
then
	echo "Usage: fstest <MOUNT_POINT>"
	exit
fi

md_test $1
fio_test $1 1
fio_test $1 4
fio_test $1 16
fio_test $1 64
```