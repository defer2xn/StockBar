"""pytest 配置：把 helper/ 加入 PYTHONPATH，让 `from quant import ...` 能 import"""
import sys
from pathlib import Path

# helper/ 目录的父级 / helper/ 本身都要可见
HELPER_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HELPER_DIR))
