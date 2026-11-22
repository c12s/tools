#!/bin/bash
# Always-fail health check: forces greenboot to fail every boot
echo "99-always-fail: deliberately failing for rollback test"
exit 1
