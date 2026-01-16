echo "=== OS ==="; cat /etc/os-release | sed -n '1,6p'
echo "=== KERNEL ==="; uname -r
echo "=== CPU ==="; lscpu | egrep 'Model name|Socket|Thread|Core|CPU\(s\)'
echo "=== MEM ==="; free -h
echo "=== DISK (lsblk) ==="; lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
echo "=== FS (df) ==="; df -hT
echo "=== VIRT ==="; systemd-detect-virt || true
echo "=== AWS IMDS (if allowed) ===";
TOKEN=$(curl -sS -m 1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || true)
if [ -n "$TOKEN" ]; then
  echo -n "instance-type: "; curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type; echo
  echo "identity:"; curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/dynamic/instance-identity/document; echo
else
  echo "IMDS not reachable"
fi
