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

