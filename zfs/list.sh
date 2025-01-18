#!/bin/bash
set -e

zfs list -o name,keystatus,canmount,mounted,mountpoint "$@"