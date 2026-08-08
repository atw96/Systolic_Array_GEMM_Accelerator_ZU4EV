#!/usr/bin/env python3
# =============================================================
# 文件名  : host_eth_receiver.py
# 描述    : 上位机（PC）以太网结果接收脚本
#           配合 software/test_app.c 的 --host/--port 使用
#
# 【需求1 实现说明】PL 端加速 + PS 端以太网上传训练/预测结果
#   本脚本在上位机（你的 PC，Windows/WSL 均可）上运行，监听 TCP 端口，
#   接收板卡 test_app 发来的 JSON Lines 格式结果，实时打印并落盘到
#   eth_results.jsonl，同时【自动调用 golden_model.py 的核对逻辑】做
#   即时 PASS/FAIL 反馈——即"边收边核对"，方便本地调试时第一时间发现
#   板卡计算是否正确，无需等到全部结果都跑完再手动比对。
#
#   【重要】用户提到希望参考自己 GitHub 上 imgproc 工程的以太网配置，
#   但该仓库内容未出现在本次对话上下文中，我没有权限访问任意用户的
#   私有/外部 GitHub 仓库。本脚本实现的是一套通用、可直接工作的参考
#   协议（原始 TCP 短连接 + 换行分隔 JSON），并在协议层做了清晰注释，
#   如果你把 imgproc 里 eth 配置相关的代码或说明发给我，下一轮可以
#   直接对齐改造（例如换成长连接、自定义二进制帧头、UDP 广播等）。
#
# 协议（须与 software/test_app.c 的 eth_upload_result() 保持一致）：
#   传输层：TCP，短连接（每条结果一次 connect/send/close）
#   应用层：单行 JSON，字段：
#     {"seq":1,"test_id":0,"array_size":8,"result":[...],
#      "pass":true,"ts":1234567890}
#
# 运行    :
#   python3 host_eth_receiver.py                      # 默认监听 0.0.0.0:9000
#   python3 host_eth_receiver.py --port 9000          # 指定端口
#   python3 host_eth_receiver.py --array_size 16       # 若阵列规模改了要同步
#
# 板端配合：
#   sudo ./test_app --host <本机IP> --port 9000
# =============================================================

import argparse
import json
import socket
import sys
import os
from datetime import datetime

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import golden_model as gm

ETH_LOG_FILE = "eth_results.jsonl"


def handle_connection(conn, addr, array_size, log_file):
    """处理一次板卡连接：读取一行 JSON，解析、落盘、核对"""
    conn.settimeout(5.0)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        print(f"[WARN] 来自 {addr} 的连接读取超时")
        return
    finally:
        conn.close()

    if not buf:
        print(f"[WARN] 来自 {addr} 的连接无数据")
        return

    line = buf.decode("utf-8", errors="replace").strip()
    try:
        rec = json.loads(line)
    except json.JSONDecodeError as e:
        print(f"[ERROR] JSON 解析失败: {e}")
        print(f"        原始数据: {line[:200]}")
        return

    # 落盘（JSON Lines，供 golden_model.py --mode eth 使用）
    with open(log_file, "a") as f:
        f.write(json.dumps(rec) + "\n")

    seq        = rec.get("seq")
    test_id    = rec.get("test_id")
    recv_size  = rec.get("array_size")
    result     = rec.get("result", [])
    board_pass = rec.get("pass")
    ts         = rec.get("ts")
    ts_str     = datetime.fromtimestamp(ts).strftime("%Y-%m-%d %H:%M:%S") if ts else "?"

    print(f"\n{'='*60}")
    print(f"  收到结果 seq={seq} test_id={test_id} 来自 {addr[0]}:{addr[1]}  ({ts_str})")
    print(f"{'='*60}")
    print(f"  板端上报 array_size = {recv_size}")
    print(f"  板端上报 result     = {result}")
    print(f"  板端自评 pass       = {board_pass}")

    if recv_size != array_size:
        print(f"  [WARN] 板端 array_size({recv_size}) 与本脚本 --array_size({array_size}) 不一致，"
              f"跳过 golden 核对")
        return

    # 【即时核对】用 golden_model 的核心函数重新计算该 test_id 的期望值，
    # 与板端上报结果做二次交叉验证（不仅信任板端自评的 pass 字段）
    try:
        tests = gm.generate_test_vectors(array_size)
        if test_id is None or test_id >= len(tests):
            print(f"  [WARN] test_id={test_id} 超出 golden_model 预置范围，跳过核对")
            return
        _, _, c_expected = tests[test_id]
        match = list(c_expected) == list(result)
        if match:
            print(f"  ✓ [HOST-VERIFIED PASS] 上位机重新核对：与 golden_model 完全一致")
        else:
            print(f"  ✗ [HOST-VERIFIED FAIL] 上位机重新核对：结果不一致！")
            print(f"    Golden = {c_expected.tolist()}")
            print(f"    Board  = {result}")
    except Exception as e:
        print(f"  [WARN] 核对过程出错: {e}")


def main():
    parser = argparse.ArgumentParser(
        description="ACU4EV GEMM 加速器 - 上位机以太网结果接收脚本"
    )
    parser.add_argument("--bind", default="0.0.0.0", help="监听地址（默认 0.0.0.0，监听所有网卡）")
    parser.add_argument("--port", type=int, default=9000, help="监听端口（默认 9000，须与板端 --port 一致）")
    parser.add_argument("--array_size", type=int, default=24,
                        help="脉动阵列规模（须与当前烧录的 bitstream / test_app 一致，默认 24）")
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.bind, args.port))
    server.listen(5)

    print("======================================================")
    print("  ACU4EV GEMM 加速器 - 以太网结果接收服务")
    print("======================================================")
    print(f"  监听地址: {args.bind}:{args.port}")
    print(f"  阵列规模: {args.array_size}x{args.array_size}")
    print(f"  落盘文件: {ETH_LOG_FILE}")
    print(f"  板端命令: sudo ./test_app --host <本机IP> --port {args.port}")
    print("  按 Ctrl+C 停止")
    print("======================================================")

    try:
        while True:
            conn, addr = server.accept()
            handle_connection(conn, addr, args.array_size, ETH_LOG_FILE)
    except KeyboardInterrupt:
        print("\n\n收到 Ctrl+C，正在停止...")
    finally:
        server.close()
        print(f"服务已停止。接收记录已保存到 {ETH_LOG_FILE}")
        print(f"可运行以下命令做完整交叉验证：")
        print(f"  python3 golden_model.py --array_size {args.array_size} --test_id 0 --mode eth")


if __name__ == "__main__":
    main()
