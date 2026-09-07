#!/bin/zsh
cd -- "${0:A:h}" || exit 1
for task_python in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [[ -x "$task_python" ]]; then
    "$task_python" ./memory_watch.py "$@"
    task_result=$?
    if (( task_result != 0 )); then
      read -r '?启动失败，按回车关闭。'
    fi
    exit "$task_result"
  fi
done
print '未找到 Python 3。请先安装 Python 3。'
read -r '?按回车关闭。'
exit 1
