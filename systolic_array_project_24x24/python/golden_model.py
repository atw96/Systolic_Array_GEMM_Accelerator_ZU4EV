#!/usr/bin/env python3
# =============================================================
# 文件名  : golden_model.py
# 描述    : INT8 脉动阵列 GEMM 黄金参考模型（ACU4EV 优化版）
# Python  : 3.9（兼容 3.8+，不使用 3.10+ match 语法）
#
# 【优化说明】对照 porting_env_hardware_config.md 中记录的板卡资源余量
# （LUT 88K / DSP48E2 728，原 4×4 设计仅用 16 个 DSP≈2.2%），
# 本次将阵列规模由固定 4×4 参数化为可配置 --array_size（默认 8），
# 与 RTL 侧 rtl/axi_ctrl_top.v 的 ARRAY_SIZE 参数保持一致。
# 若修改了 RTL 的 ARRAY_SIZE，务必同步修改这里的 --array_size 默认值。
#
# 运行    :
#   # 生成测试向量并打印仿真数据流（默认 N=24）
#   python3 golden_model.py --test_id 0 --mode gen
#   # 与 xsim 仿真结果比对
#   python3 golden_model.py --test_id 0 --mode sim
#   # 与板卡实测日志比对
#   python3 golden_model.py --test_id 0 --mode board
#   # 与以太网上传结果比对（host_eth_receiver.py 落盘的 JSON Lines）
#   python3 golden_model.py --test_id 0 --mode eth
#   # 指定阵列规模（须与当前烧录的 bitstream 一致）
#   python3 golden_model.py --array_size 16 --test_id 0 --mode gen
# =============================================================

import argparse
import json
import numpy as np
import os
import sys

# ── 默认常量 ──────────────────────────────────────────────────
DEFAULT_ARRAY_SIZE = 24      # 须与 rtl/axi_ctrl_top.v 的 ARRAY_SIZE 默认值同步
FIXED_SEED          = 42
RESULT_FILE   = "sim_work/result.txt"        # xsim 输出文件
BOARD_LOG     = "board_result.txt"           # 板卡 test_app 输出日志（串口/SSH）
ETH_LOG_FILE  = "eth_results.jsonl"          # host_eth_receiver.py 落盘的接收记录


# =============================================================
# 核心函数 1：INT8 GEMM 黄金模型（与阵列规模无关，保持通用）
# 说明：
#   不直接用 np.matmul 的原因：
#   np.matmul 内部使用浮点或系统默认精度，可能引入舍入误差。
#   本函数手动实现 INT8 × INT8 → INT32 累加，与 RTL 行为完全一致。
#   每次乘加都在 INT32 域内进行，保证位精确（bit-accurate）匹配。
# =============================================================
def int8_gemm_golden(A: np.ndarray, B: np.ndarray) -> np.ndarray:
    """
    精确模拟 INT8 脉动阵列 GEMM。
    A: (M, K) INT8 矩阵
    B: (K, N) INT8 矩阵（权重矩阵，K=N=array_size）
    返回: (M, N) INT32 矩阵
    """
    M, K = A.shape
    K2, N = B.shape
    assert K == K2, f"维度不匹配: A({M},{K}) x B({K2},{N})"
    assert K == N, f"本设计仅支持方阵脉动阵列，当前 K={K} != N={N}"

    A = A.astype(np.int8)
    B = B.astype(np.int8)
    C = np.zeros((M, N), dtype=np.int32)

    for m in range(M):
        for n in range(N):
            acc = np.int32(0)
            for k in range(K):
                product = np.int32(A[m, k]) * np.int32(B[k, n])
                acc += product
            C[m, n] = acc

    return C


# =============================================================
# 核心函数 2：逐拍仿真脉动阵列数据流（参数化 array_size）
# =============================================================
def simulate_systolic_dataflow(A_row: np.ndarray, B: np.ndarray,
                                array_size: int) -> np.ndarray:
    """
    逐拍模拟 array_size × array_size Weight Stationary 脉动阵列。
    """
    total_cycles = 2 * array_size - 1
    print(f"\n{'='*60}")
    print(f"  逐拍数据流仿真（{array_size}x{array_size}，共 {total_cycles} 拍）")
    print(f"  A_row = {A_row.tolist()}")
    if array_size <= 8:
        print(f"  B =")
        for r in B:
            print(f"         {r.tolist()}")
    else:
        print(f"  B = <{array_size}x{array_size} 矩阵，规模较大不逐行打印>")
    print(f"{'='*60}")

    psum = np.zeros((array_size + 1, array_size), dtype=np.int32)

    # 仅在阵列规模较小时打印逐拍 PE 状态（避免大阵列刷屏）
    verbose = array_size <= 8

    for cycle in range(total_cycles + 2):
        if verbose:
            print(f"\n  Cycle {cycle:2d}:")
        for row in range(array_size):
            for col in range(array_size):
                if cycle == row + col:
                    a_val = np.int32(A_row[row])
                    b_val = np.int32(B[row, col])
                    psum[row + 1][col] += a_val * b_val
                    if verbose:
                        print(f"    PE[{row}][{col}]: A={a_val:4d} × B={b_val:4d} "
                              f"= {a_val*b_val:6d}, psum→{psum[row+1][col]:8d}")

        if cycle == total_cycles - 1 and verbose:
            print(f"\n  *** Cycle {cycle}: result_valid 置高 ***")

    result = psum[array_size, :].copy()
    print(f"\n  最终结果: {result.tolist()}")
    return result


# =============================================================
# 测试向量生成（固定 seed=42，参数化 array_size）
# =============================================================
def generate_test_vectors(array_size: int, num_tests: int = 5) -> list:
    """
    生成 num_tests 组测试向量（array_size x array_size）。
    返回列表，每个元素为 (A_row, B, C_expected)
    """
    rng = np.random.default_rng(FIXED_SEED)
    tests = []
    for i in range(num_tests):
        A_row = rng.integers(-128, 127, size=(array_size,), dtype=np.int8)
        B     = rng.integers(-128, 127, size=(array_size, array_size), dtype=np.int8)
        C_row = int8_gemm_golden(A_row.reshape(1, -1), B)[0]
        tests.append((A_row, B, C_row))
    return tests


# =============================================================
# 输出 $readmemh 格式（供 Verilog testbench 使用）
# =============================================================
def export_readmemh(A_row: np.ndarray, B: np.ndarray,
                    C_expected: np.ndarray, test_id: int,
                    array_size: int) -> None:
    os.makedirs("sim_work", exist_ok=True)

    fname_a = f"sim_work/test{test_id}_a.mem"
    with open(fname_a, "w") as f:
        for val in A_row:
            f.write(f"{int(val) & 0xFF:02x}\n")
    print(f"  A 向量写入: {fname_a}")

    fname_b = f"sim_work/test{test_id}_b.mem"
    with open(fname_b, "w") as f:
        for row in range(array_size):
            for col in range(array_size):
                f.write(f"{int(B[row, col]) & 0xFF:02x}\n")
    print(f"  B 矩阵写入: {fname_b}")

    fname_c = f"sim_work/test{test_id}_c_expected.mem"
    with open(fname_c, "w") as f:
        for val in C_expected:
            f.write(f"{int(val) & 0xFFFFFFFF:08x}\n")
    print(f"  期望结果写入: {fname_c}")


# =============================================================
# 与 xsim 结果比对
# =============================================================
def compare_sim_result(test_id: int, array_size: int) -> bool:
    tests = generate_test_vectors(array_size)
    if test_id >= len(tests):
        print(f"[ERROR] test_id={test_id} 超出范围（最大 {len(tests)-1}）")
        return False

    A_row, B, C_expected = tests[test_id]

    if not os.path.exists(RESULT_FILE):
        print(f"[ERROR] 仿真结果文件不存在: {RESULT_FILE}")
        print(f"        请先运行: bash scripts/run_xsim_full.sh")
        return False

    with open(RESULT_FILE, "r") as f:
        lines = [line.strip() for line in f if line.strip()]

    if len(lines) < array_size:
        print(f"[ERROR] 结果文件行数不足: {len(lines)} < {array_size}")
        return False

    sim_result = np.array([int(l) for l in lines[:array_size]], dtype=np.int32)

    print(f"\n{'='*60}")
    print(f"  xsim 仿真结果比对（test_id={test_id}, N={array_size}）")
    print(f"{'='*60}")
    print(f"  Golden     = {C_expected.tolist()}")
    print(f"  Sim Result = {sim_result.tolist()}")

    match = np.array_equal(C_expected, sim_result)
    if match:
        print(f"\n  ✓ [PASS] 仿真结果与 Golden Model 完全一致")
    else:
        print(f"\n  ✗ [FAIL] 结果不匹配！")
        diff = C_expected.astype(np.int64) - sim_result.astype(np.int64)
        print(f"  差值 = {diff.tolist()}")
    return match


# =============================================================
# 通用：从任意文本中解析 "RESULT_i: value" 格式（board / 手工日志用）
# =============================================================
def _parse_result_lines(lines, array_size: int):
    values = {}
    for line in lines:
        line = line.strip()
        if line.startswith("RESULT_") and ":" in line:
            key, _, val_str = line.partition(":")
            try:
                idx = int(key.strip().split("_")[1])
                val = int(val_str.strip())
                if 0 <= idx < array_size:
                    values[idx] = val
            except (ValueError, IndexError):
                continue
    if len(values) < array_size:
        return None
    return np.array([values[i] for i in range(array_size)], dtype=np.int32)


# =============================================================
# 与板卡实测日志比对（串口 / SSH 输出，RESULT_0..N-1 格式通用解析）
# =============================================================
def compare_board_result(test_id: int, array_size: int) -> bool:
    tests = generate_test_vectors(array_size)
    A_row, B, C_expected = tests[test_id]

    if not os.path.exists(BOARD_LOG):
        print(f"[ERROR] 板卡日志不存在: {BOARD_LOG}")
        print(f"        请将板卡 test_app 的输出重定向到此文件，例如：")
        print(f"        ssh root@\\$BOARD_IP './test_app' | tee {BOARD_LOG}")
        return False

    with open(BOARD_LOG, "r") as f:
        lines = f.readlines()

    board_arr = _parse_result_lines(lines, array_size)
    if board_arr is None:
        print(f"[ERROR] 日志中未找到全部 {array_size} 个 RESULT_i 结果")
        print(f"        请检查日志是否包含 RESULT_0: ~ RESULT_{array_size-1}:")
        return False

    print(f"\n{'='*60}")
    print(f"  板卡实测结果比对（test_id={test_id}, N={array_size}）")
    print(f"{'='*60}")
    print(f"  Golden      = {C_expected.tolist()}")
    print(f"  Board Result= {board_arr.tolist()}")

    match = np.array_equal(C_expected, board_arr)
    if match:
        print(f"\n  ✓ [PASS] 板卡结果与 Golden Model 完全一致 — 上板验证成功！")
    else:
        print(f"\n  ✗ [FAIL] 板卡结果不匹配")
        diff = C_expected.astype(np.int64) - board_arr.astype(np.int64)
        print(f"  差值 = {diff.tolist()}")
    return match


# =============================================================
# 【新增】与以太网上传结果比对
# 读取 host_eth_receiver.py 落盘的 JSON Lines 文件（eth_results.jsonl），
# 每行一条 JSON 记录，字段与 software/eth_client.c 发送的协议一致：
#   {"test_id": 0, "array_size": 8, "result": [.....], "seq": 1, "ts": "..."}
# =============================================================
def compare_eth_result(test_id: int, array_size: int) -> bool:
    tests = generate_test_vectors(array_size)
    A_row, B, C_expected = tests[test_id]

    if not os.path.exists(ETH_LOG_FILE):
        print(f"[ERROR] 以太网接收记录不存在: {ETH_LOG_FILE}")
        print(f"        请先在上位机运行: python3 python/host_eth_receiver.py")
        print(f"        并确保板端已通过 test_app --host <上位机IP> 发送结果")
        return False

    matched_record = None
    with open(ETH_LOG_FILE, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("test_id") == test_id and rec.get("array_size") == array_size:
                matched_record = rec  # 取最后一条匹配记录（最新一次上传）

    if matched_record is None:
        print(f"[ERROR] {ETH_LOG_FILE} 中未找到 test_id={test_id}, array_size={array_size} 的记录")
        return False

    eth_result = np.array(matched_record["result"], dtype=np.int32)

    print(f"\n{'='*60}")
    print(f"  以太网上传结果比对（test_id={test_id}, N={array_size}）")
    print(f"  来源记录: seq={matched_record.get('seq')}, ts={matched_record.get('ts')}")
    print(f"{'='*60}")
    print(f"  Golden      = {C_expected.tolist()}")
    print(f"  ETH Result  = {eth_result.tolist()}")

    match = np.array_equal(C_expected, eth_result)
    if match:
        print(f"\n  ✓ [PASS] 以太网上传结果与 Golden Model 完全一致")
    else:
        print(f"\n  ✗ [FAIL] 结果不匹配")
        diff = C_expected.astype(np.int64) - eth_result.astype(np.int64)
        print(f"  差值 = {diff.tolist()}")
    return match


# =============================================================
# 主程序入口
# =============================================================
def main() -> None:
    parser = argparse.ArgumentParser(
        description="INT8 脉动阵列 GEMM Golden Model（ACU4EV 优化版）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python3 golden_model.py --test_id 0 --mode gen     # 生成向量 + 打印数据流（N=24）
  python3 golden_model.py --test_id 0 --mode sim     # 与 xsim 结果比对
  python3 golden_model.py --test_id 0 --mode board   # 与板卡日志比对
  python3 golden_model.py --test_id 0 --mode eth     # 与以太网上传结果比对
  python3 golden_model.py --array_size 16 --list     # 用 16x16 规模列出向量
        """
    )
    parser.add_argument("--test_id", type=int, default=0,
                        help="测试向量 ID（0~4，默认 0）")
    parser.add_argument("--array_size", type=int, default=DEFAULT_ARRAY_SIZE,
                        help=f"脉动阵列规模 N（须与当前烧录的 bitstream 一致，默认 {DEFAULT_ARRAY_SIZE}）")
    parser.add_argument("--mode", choices=["gen", "sim", "board", "eth"], default="gen",
                        help="运行模式：gen=生成, sim=对比仿真, board=对比板卡日志, eth=对比以太网上传结果")
    parser.add_argument("--list", action="store_true",
                        help="列出所有 5 组测试向量的期望结果")
    args = parser.parse_args()

    N = args.array_size
    tests = generate_test_vectors(N)

    if args.list:
        print(f"\n{'='*60}")
        print(f"  所有测试向量（{N}x{N}, seed={FIXED_SEED}）")
        print(f"{'='*60}")
        for i, (A_row, B, C) in enumerate(tests):
            print(f"  test_id={i}: A={A_row.tolist()}")
            print(f"              C={C.tolist()}")
        return

    if args.test_id >= len(tests):
        print(f"[ERROR] test_id={args.test_id} 超出范围（最大 {len(tests)-1}）")
        sys.exit(1)

    A_row, B, C_expected = tests[args.test_id]

    if args.mode == "gen":
        print(f"\n{'='*60}")
        print(f"  测试向量 test_id={args.test_id}（{N}x{N}）")
        print(f"{'='*60}")
        print(f"  A[0] = {A_row.tolist()}")
        if N <= 8:
            print(f"  B =")
            for row in B:
                print(f"         {row.tolist()}")
        print(f"  期望 C[0] = {C_expected.tolist()}")

        result_check = simulate_systolic_dataflow(A_row, B, N)

        print(f"\n  导出 $readmemh 格式文件...")
        export_readmemh(A_row, B, C_expected, args.test_id, N)

        if np.array_equal(C_expected, result_check):
            print(f"\n  ✓ 逐拍模拟结果验证通过")
        else:
            print(f"\n  ✗ 逐拍模拟结果不一致（请检查 simulate_systolic_dataflow）")

    elif args.mode == "sim":
        success = compare_sim_result(args.test_id, N)
        sys.exit(0 if success else 1)

    elif args.mode == "board":
        success = compare_board_result(args.test_id, N)
        sys.exit(0 if success else 1)

    elif args.mode == "eth":
        success = compare_eth_result(args.test_id, N)
        sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
