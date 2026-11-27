# -*- coding: utf-8 -*-
"""
微信群聊同步助手 · 自动监听转发版

功能：盯住一个「源群」，把群里任何人发的新消息，按

        来自 源群名 的 发送者 ：
        --------------------------------
        消息内容

    的格式，自动转发到你指定的多个「目标群」。

原理：「窗口截图 → OCR 识别 → 比对新增 → Windows UI 自动化发送」。
      发送过程中会临时切到目标群，发完自动切回源群。

限制：仅支持文字消息；图片/表情/文件/引用无法识别；
      监听期间微信必须保持登录，且不要手动操作微信窗口。

运行环境：Windows 10/11 x64、Python 3.12 x64、微信电脑版。
通过 start-windows.bat 安装依赖并启动。
"""

import ctypes
import json
import math
import os
import re
import sys
import threading
import time
import tkinter as tk
from tkinter import ttk, messagebox, scrolledtext
from relay_logic import (
    DeliveryUncertain, DesktopUnavailable, PendingDelivery, SnapshotTracker,
    group_title_matches, relay_echo, unique_targets,
)


# ----------------------------------------------------------------------------
# 启动环境自检
# ----------------------------------------------------------------------------
def _fatal(title, message):
    try:
        r = tk.Tk()
        r.withdraw()
        messagebox.showerror(title, message)
        r.destroy()
    except Exception:
        print(f"{title}: {message}")
    sys.exit(1)


def _is_admin():
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False


def _config_path():
    base = os.path.dirname(os.path.abspath(__file__))
    if os.access(base, os.W_OK):
        return os.path.join(base, "wechat_relay_config.json")
    home = os.path.join(os.path.expanduser("~"), ".wechat_group_sync")
    try:
        os.makedirs(home, exist_ok=True)
    except Exception:
        return os.path.join(base, "wechat_relay_config.json")
    return os.path.join(home, "wechat_relay_config.json")


auto = None  # initialized only by main(); safe to import for offline tests

CONFIG_PATH = _config_path()


# ----------------------------------------------------------------------------
# 窗口操作
# ----------------------------------------------------------------------------
def _dpi_scale(win=None):
    try:
        user32 = _user32()
        d = user32.GetDpiForWindow(win.NativeWindowHandle) if win is not None else user32.GetDpiForSystem()
        if d:
            return d / 96.0
    except Exception:
        pass
    return 1.0


_MAIN_TITLES = ("微信", "WeChat", "Weixin")


def _user32():
    from ctypes import wintypes
    api = ctypes.windll.user32
    api.GetForegroundWindow.restype = wintypes.HWND
    api.WindowFromPoint.argtypes = [wintypes.POINT]
    api.WindowFromPoint.restype = wintypes.HWND
    api.GetAncestor.argtypes = [wintypes.HWND, wintypes.UINT]
    api.GetAncestor.restype = wintypes.HWND
    for method in (api.IsWindowVisible, api.IsIconic, api.SetForegroundWindow,
                   api.GetDpiForWindow, api.GetWindowTextLengthW):
        method.argtypes = [wintypes.HWND]
    api.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    api.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    api.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    api.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
    return api


def _enum_windows():
    """枚举所有顶层窗口（含隐藏的），返回 [(hwnd, title, cls, visible, rect)]。"""
    from ctypes import wintypes
    u = _user32()
    out = []
    proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)

    def cb(hwnd, _):
        n = u.GetWindowTextLengthW(hwnd)
        if n <= 0:
            return True
        buf = ctypes.create_unicode_buffer(n + 1)
        u.GetWindowTextW(hwnd, buf, n + 1)
        title = buf.value.strip()
        cbuf = ctypes.create_unicode_buffer(256)
        u.GetClassNameW(hwnd, cbuf, 256)
        cls = cbuf.value
        if not any(prefix in cls.casefold() for prefix in ("qt5", "qt6", "wechat", "weixin")):
            return True
        r = wintypes.RECT()
        u.GetWindowRect(hwnd, ctypes.byref(r))
        out.append((hwnd, title, cls, bool(u.IsWindowVisible(hwnd)),
                    (r.left, r.top, r.right, r.bottom)))
        return True

    u.EnumWindows(proc(cb), 0)
    return out


def find_wechat_window():
    """只连接唯一并可见的微信主窗口。"""
    matches = [
        hwnd for hwnd, title, _, visible, rect in _enum_windows()
        if visible and title in _MAIN_TITLES and rect[2] - rect[0] >= 800 and rect[3] - rect[1] >= 500
    ]
    return auto.ControlFromHandle(matches[0]) if len(matches) == 1 else None


def activate_window(win):
    _user32().SetForegroundWindow(win.NativeWindowHandle)
    time.sleep(0.2)
    _require_foreground(win)


def _require_foreground(win):
    if _user32().GetForegroundWindow() != win.NativeWindowHandle:
        raise DesktopUnavailable("微信主窗口不在前台。请恢复窗口并重新开始监听。")


def _require_window_at(win, x, y):
    from ctypes import wintypes
    _require_foreground(win)
    api = _user32()
    at_point = api.WindowFromPoint(wintypes.POINT(int(x), int(y)))
    if not at_point or api.GetAncestor(at_point, 2) != win.NativeWindowHandle:
        raise DesktopUnavailable("微信识别区域被遮挡或在屏幕外。请调整窗口后重新开始。")


def _grab(win, left, top, right, bottom, *, allow_blank=False):
    import numpy as np
    from mss import MSS

    if right <= left or bottom <= top:
        raise DesktopUnavailable("识别区域无效。请放大微信窗口或调整边距。")
    _require_window_at(win, left + 2, top + 2)
    _require_window_at(win, right - 2, bottom - 2)
    with MSS() as sct:
        shot = sct.grab({"left": left, "top": top,
                         "width": right - left, "height": bottom - top})
    image = np.frombuffer(shot.bgra, dtype=np.uint8).reshape(shot.height, shot.width, 4)[:, :, :3].copy()
    _require_foreground(win)
    if not allow_blank and int(image.max()) - int(image.min()) < 8:
        raise DesktopUnavailable("截图近乎空白。请核对识别区域及微信窗口。")
    return image


def _click(win, x, y):
    _require_window_at(win, x, y)
    auto.Click(int(x), int(y))


def _keys(win, keys, wait):
    _require_foreground(win)
    auto.SendKeys(keys, waitTime=wait)


def _ocr_lines(engine, img, min_score=0.55):
    result, _ = engine(img)
    rows = []
    for box, text, score in result or []:
        text = (text or "").strip()
        if not text or float(score) < min_score:
            continue
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        rows.append({"text": text, "x0": min(xs), "y0": min(ys),
                     "x1": max(xs), "y1": max(ys)})
    rows.sort(key=lambda r: r["y0"])
    return rows


_SECTION_WORDS = ("最常使用", "联系人", "群聊", "公众号", "服务号",
                  "小程序", "聊天记录", "功能", "搜索网络结果", "全部", "更多")


def _is_section_header(text):
    t = text.strip()
    return t.startswith("查看全部") or t in _SECTION_WORDS


def _find_group_row(rows, name):
    """在搜索结果里定位群会话，返回 (行, 是否群聊分区) ；找不到返回 (None, False)。

    只在「群聊」和「最常使用」两个分区里找，绝不点「联系人」/「聊天记录」，
    避免把群消息发到同名的个人聊天。
    """
    headers = [(r["y0"], r["text"].strip()) for r in rows if _is_section_header(r["text"])]
    headers.sort()

    def band(start_y):
        end_y = None
        for y, _ in headers:
            if y > start_y:
                end_y = y
                break
        return [r for r in rows if r["y0"] > start_y and (end_y is None or r["y0"] < end_y)]

    for word, is_group in (("群聊", True), ("最常使用", False)):
        ys = [y for y, t in headers if t == word]
        if not ys:
            continue
        matches = [row for y in ys for row in band(y) if row["text"].strip() == name]
        if len(matches) > 1:
            raise RuntimeError(f"搜索到多个同名群「{name}」，请先区分群名。")
        if matches:
            return matches[0], is_group
    return None, False


def read_chat_title(win, engine):
    """OCR 读取聊天区顶部标题（形如「群名 (人数)」）。"""
    r = win.BoundingRectangle
    width = r.right - r.left
    s = _dpi_scale(win)
    img = _grab(win, r.left + int(310 * s), r.top + int(20 * s),
                r.left + int(width * 0.86), r.top + int(84 * s), allow_blank=True)
    lines = _ocr_lines(engine, img, 0.66)
    if not lines:
        return ""
    first = lines[0]
    same_row = [line for line in lines if abs(line["y0"] - first["y0"]) <= int(6 * s)]
    return " ".join(line["text"] for line in sorted(same_row, key=lambda line: line["x0"]))


def goto_chat(win, name, engine, attempts=3):
    """点搜索框 → 输入群名 → 点精确匹配的行 → 校验标题。失败抛异常。"""
    dropdown_hints = ("最常使用", "群聊", "联系人", "聊天记录", "查看全部", "更多")
    seen_names = []
    for _ in range(attempts):
        _require_foreground(win)
        r = win.BoundingRectangle
        W, H = r.right - r.left, r.bottom - r.top
        s = _dpi_scale(win)

        # 点击会话列表顶部的搜索框（比 Ctrl+F 稳定）
        _click(win, r.left + int(167 * s), r.top + int(53 * s))
        time.sleep(0.35)
        _keys(win, "{Ctrl}a", 0.1)
        auto.SetClipboardText(name)
        _keys(win, "{Ctrl}v", 0.6)

        search_width = min(W - 20, max(int(360 * s), int(W * 0.26)))
        rows = _ocr_lines(engine, _grab(win, r.left + 6, r.top + 6,
                                        r.left + search_width, r.top + int(H * 0.72)), 0.60)
        seen_names = [row["text"] for row in rows
                      if row["y0"] > 120 and not _is_section_header(row["text"])][:6]
        opened = any(any(h in row["text"] for h in dropdown_hints) for row in rows)
        if opened:
            row, _ = _find_group_row(rows, name)
            if row is not None:
                _click(win, r.left + 6 + (row["x0"] + row["x1"]) / 2.0,
                       r.top + 6 + (row["y0"] + row["y1"]) / 2.0)
                time.sleep(0.75)
                if group_title_matches(read_chat_title(win, engine), name):
                    return True
        _keys(win, "{Esc}", 0.2)
    raise RuntimeError(f"无法定位会话「{name}」，请确认群名与微信里完全一致。"
                       f"搜索到的结果：{seen_names or '（无）'}")


def ensure_chat(win, name, engine):
    """已在目标会话就不重复搜索，否则执行定位。"""
    if group_title_matches(read_chat_title(win, engine), name):
        return True
    return goto_chat(win, name, engine)


def focus_input(win):
    """点击消息输入框，确保后续粘贴进入输入框而不是别处。"""
    r = win.BoundingRectangle
    s = _dpi_scale(win)
    _click(win, r.left + int(350 * s), r.bottom - int(90 * s))
    time.sleep(0.15)


def send_text(win, text, send_key="Enter", expected_group=None, engine=None, stopped=None):
    if not expected_group or not group_title_matches(read_chat_title(win, engine), expected_group):
        raise RuntimeError("发送前群标题核验失败，已阻止发送")
    r = win.BoundingRectangle
    s = _dpi_scale(win)
    composer = _grab(win, r.left + int(330 * s), r.bottom - int(110 * s),
                     r.right - int(70 * s), r.bottom - int(48 * s), allow_blank=True)
    if _ocr_lines(engine, composer, 0.50):
        raise RuntimeError("输入框似乎已有内容。请检查草稿并清空输入框后再试。")
    if stopped is not None and stopped():
        return False
    focus_input(win)
    try:
        auto.SetClipboardText(text)
        _keys(win, "{Ctrl}v", 0.35)
        if stopped is not None and stopped():
            return False
        if not group_title_matches(read_chat_title(win, engine), expected_group):
            raise DeliveryUncertain("粘贴后群标题改变，已跳过发送。请核对输入框。")
        _keys(win, "{Ctrl}{Enter}" if send_key == "Ctrl+Enter" else "{Enter}", 0.35)
    except Exception as e:
        raise DeliveryUncertain("桌面发送操作异常，无法确定是否已发出；请人工核对") from e
    return True


# ----------------------------------------------------------------------------
# 截图 + OCR
# ----------------------------------------------------------------------------
def grab_region(win, left_px=320, top_px=100, bottom_px=155):
    """按固定逻辑像素偏移截取消息区（窗口大小变化时依然有效）。"""
    r = win.BoundingRectangle
    s = _dpi_scale(win)
    left = r.left + int(left_px * s)
    top = r.top + int(top_px * s)
    right = r.right - 6
    bottom = r.bottom - int(bottom_px * s)
    if right - left < 50 or bottom - top < 50:
        raise RuntimeError("窗口尺寸异常，无法截图")
    return _grab(win, left, top, right, bottom, allow_blank=True)


_NOISE_RE = [
    r"^\d{1,2}:\d{2}$",
    r"^(昨天|今天|前天|上午|下午|凌晨|中午|晚上)(\s*\d{1,2}:\d{2})?$",
    r"^星期[一二三四五六日天]$",
    r"^\d{4}年\d{1,2}月\d{1,2}日.*$",
    r"^\d{1,2}月\d{1,2}日.*$",
]
_SYS_HINT = ("撤回了一条消息", "加入了群聊", "退出了群聊", "修改群名",
             "开启了朋友验证", "你已添加", "以上是打招呼的内容")
_NON_TEXT = re.compile(
    r"^[\[【](?:图片|照片|视频|语音|表情|动画表情|文件|引用|合并转发|聊天记录|小程序|链接|位置|名片|红包)[\]】]"
    r"|^(?:引用[：:]|转发的聊天记录$|聊天记录$|打开小程序$|点击查看原消息$|微信红包$)"
)
_VISIBLE_WORD = re.compile(r"[^\W_]", re.UNICODE)


def _is_noise_block(text):
    t = text.strip()
    if not t:
        return True
    for p in _NOISE_RE:
        if re.match(p, t):
            return True
    for h in _SYS_HINT:
        if h in t:
            return True
    return False


def parse_messages(engine, img, min_score=0.75):
    """把截图解析成 [(发送者, 内容), ...]，按从上到下排序。"""
    h, w = img.shape[:2]
    result, _ = engine(img)
    if not result:
        return []

    items = []
    for box, text, score in result:
        text = (text or "").strip()
        if not text or float(score) < min_score:
            continue
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        items.append({
            "x0": min(xs), "x1": max(xs), "y0": min(ys), "y1": max(ys),
            "text": text,
        })
    if not items:
        return []

    heights = sorted(i["y1"] - i["y0"] for i in items)
    p75 = heights[min(len(heights) - 1, int(len(heights) * 0.75))]
    min_h = max(12, p75 * 0.62)          # 过滤掉时间戳、转发卡片里的小字
    items = [i for i in items if (i["y1"] - i["y0"]) >= min_h]
    if not items:
        return []

    items.sort(key=lambda i: i["y0"])
    gap = max(16, p75 * 0.9)             # 同一消息内行距小，跨消息间距大
    blocks, cur, last_bottom = [], [], None
    for it in items:
        if cur and it["y0"] - last_bottom > gap:
            blocks.append(cur)
            cur = []
        cur.append(it)
        last_bottom = it["y1"]
    if cur:
        blocks.append(cur)

    out = []
    for b in blocks:
        if any(_NON_TEXT.search(it["text"].strip()) for it in b):
            continue
        if len(b) == 1:
            it = b[0]
            if _is_noise_block(it["text"]) or not _VISIBLE_WORD.search(it["text"]):
                continue
            center = (it["x0"] + it["x1"]) / 2.0
            if w * 0.43 < center <= w * 0.55:
                continue
            # An incoming image or sticker can leave only its sender label in OCR.
            if center <= w * 0.43 and it["x0"] < max(32, w * 0.025):
                continue
            out.append(("我" if center > w * 0.55 else "", it["text"]))
            continue

        first, second = b[0], b[1]
        sender, body = "", b
        # 群聊里发送者昵称在气泡上方，且比气泡正文更靠左（气泡有内边距）
        if len(first["text"]) <= 24 and first["x0"] < second["x0"] - 6:
            sender, body = first["text"], b[1:]

        content = "\n".join(x["text"] for x in body).strip()
        if not content or _is_noise_block(content) or not _VISIBLE_WORD.search(content):
            continue
        if not sender:
            sender = "我" if (first["x0"] + first["x1"]) / 2.0 > w * 0.55 else ""
        out.append((sender, content))
    return out


def format_message(source_group, sender, content):
    return f"来自 {source_group} 的 {sender or '未知'} ：\n--------------------------------\n{content}"


# ----------------------------------------------------------------------------
# 主界面
# ----------------------------------------------------------------------------
class RelayApp:
    def __init__(self, root):
        self.root = root
        self.root.title("微信群聊同步助手 · 自动监听转发")
        self.root.geometry("760x720")
        self.root.minsize(680, 620)

        self._stop = threading.Event()
        self._thread = None
        self._engine = None

        self.targets = []
        self.source_var = tk.StringVar(value="")
        self.own_name_var = tk.StringVar(value="")
        self.poll_var = tk.DoubleVar(value=3.0)
        self.interval_var = tk.DoubleVar(value=5.0)
        self.dry_run_var = tk.BooleanVar(value=True)
        self.send_key_var = tk.StringVar(value="Enter")
        self.left_var = tk.DoubleVar(value=320)
        self.top_var = tk.DoubleVar(value=100)
        self.bottom_var = tk.DoubleVar(value=155)

        self._build_ui()
        self._load_config()
        self._check_env()

    # ---------------- UI ----------------
    def _build_ui(self):
        tip = tk.Label(
            self.root, anchor="w", justify="left", fg="#8a5a00", bg="#fff7e0",
            padx=8, pady=6,
            text="监听期间请勿操作微信：工具会反复切换会话做识别和发送。\n"
                 "首次请用「演练模式」验证群名和识别结果。验收后关闭演练即可实发。"
        )
        tip.pack(fill="x", padx=10, pady=(10, 4))

        # 源群
        row = ttk.Frame(self.root)
        row.pack(fill="x", padx=10, pady=4)
        ttk.Label(row, text="源群（被监听）").pack(side="left")
        ttk.Entry(row, textvariable=self.source_var).pack(side="left", fill="x", expand=True, padx=6)
        ttk.Label(row, text="我的群昵称（可选）").pack(side="left")
        ttk.Entry(row, textvariable=self.own_name_var, width=14).pack(side="left", padx=6)

        # 目标群
        box1 = ttk.LabelFrame(self.root, text="目标群（转发到这些群，每行一个）")
        box1.pack(fill="both", expand=True, padx=10, pady=4)

        wrap = ttk.Frame(box1)
        wrap.pack(fill="both", expand=True, padx=6, pady=6)
        self.listbox = tk.Listbox(wrap, height=6, activestyle="dotbox")
        self.listbox.pack(side="left", fill="both", expand=True)
        sb = ttk.Scrollbar(wrap, orient="vertical", command=self.listbox.yview)
        sb.pack(side="left", fill="y")
        self.listbox.config(yscrollcommand=sb.set)

        btns = ttk.Frame(box1)
        btns.pack(fill="x", padx=6, pady=(0, 6))
        self.entry_group = ttk.Entry(btns)
        self.entry_group.pack(side="left", fill="x", expand=True, padx=(0, 6))
        self.entry_group.bind("<Return>", lambda e: self._add_group())
        ttk.Button(btns, text="添加", width=6, command=self._add_group).pack(side="left", padx=2)
        ttk.Button(btns, text="删除选中", width=9, command=self._remove_group).pack(side="left", padx=2)
        ttk.Button(btns, text="批量导入", width=9, command=self._import_groups).pack(side="left", padx=2)
        ttk.Button(btns, text="清空", width=6, command=self._clear_groups).pack(side="left", padx=2)

        # 选项
        box2 = ttk.LabelFrame(self.root, text="选项")
        box2.pack(fill="x", padx=10, pady=4)

        r1 = ttk.Frame(box2)
        r1.pack(fill="x", padx=6, pady=4)
        ttk.Label(r1, text="识别间隔(秒)").pack(side="left")
        ttk.Spinbox(r1, from_=2, to=60, increment=1, width=5, textvariable=self.poll_var).pack(side="left", padx=(4, 14))
        ttk.Label(r1, text="发送间隔(秒)").pack(side="left")
        ttk.Spinbox(r1, from_=2, to=120, increment=1, width=5, textvariable=self.interval_var).pack(side="left", padx=(4, 14))
        ttk.Label(r1, text="发送键").pack(side="left")
        ttk.Combobox(r1, textvariable=self.send_key_var, width=10, state="readonly",
                     values=["Enter", "Ctrl+Enter"]).pack(side="left", padx=4)

        r2 = ttk.Frame(box2)
        r2.pack(fill="x", padx=6, pady=(0, 4))
        ttk.Checkbutton(r2, text="演练模式（只识别并打印，不发送）", variable=self.dry_run_var).pack(side="left")

        r3 = ttk.Frame(box2)
        r3.pack(fill="x", padx=6, pady=(0, 6))
        ttk.Label(r3, text="识别区域：左边距").pack(side="left")
        ttk.Spinbox(r3, from_=100, to=700, increment=10, width=5, textvariable=self.left_var).pack(side="left", padx=2)
        ttk.Label(r3, text="上边距").pack(side="left")
        ttk.Spinbox(r3, from_=0, to=400, increment=5, width=5, textvariable=self.top_var).pack(side="left", padx=2)
        ttk.Label(r3, text="下边距").pack(side="left")
        ttk.Spinbox(r3, from_=50, to=400, increment=5, width=5, textvariable=self.bottom_var).pack(side="left", padx=2)
        ttk.Label(r3, text="(px)").pack(side="left")
        self.btn_test = ttk.Button(r3, text="截图并解析", command=self._test_ocr)
        self.btn_test.pack(side="left", padx=10)

        # 操作
        actions = ttk.Frame(self.root)
        actions.pack(fill="x", padx=10, pady=6)
        self.btn_start = ttk.Button(actions, text="▶  开始监听", command=self._start)
        self.btn_start.pack(side="left")
        self.btn_stop = ttk.Button(actions, text="■  停止", command=self._stop_relay, state="disabled")
        self.btn_stop.pack(side="left", padx=8)
        ttk.Button(actions, text="清空日志", command=self._clear_log).pack(side="left")

        box3 = ttk.LabelFrame(self.root, text="运行日志")
        box3.pack(fill="both", expand=True, padx=10, pady=(4, 10))
        self.log_text = scrolledtext.ScrolledText(box3, height=9, wrap="word", state="disabled")
        self.log_text.pack(fill="both", expand=True, padx=6, pady=6)
        self.log_text.tag_config("ok", foreground="#1a7f37")
        self.log_text.tag_config("err", foreground="#c62828")
        self.log_text.tag_config("warn", foreground="#b26a00")

    # ---------------- 数据 ----------------
    def _refresh_list(self):
        self.listbox.delete(0, tk.END)
        for g in self.targets:
            self.listbox.insert(tk.END, g)

    def _add_group(self):
        name = self.entry_group.get().strip()
        if not name:
            return
        if name == self.source_var.get().strip():
            self.log("目标群不能与源群相同（会造成无限转发）", "warn")
            return
        if name in self.targets:
            self.log(f"群「{name}」已在列表中", "warn")
        else:
            self.targets.append(name)
            self._refresh_list()
        self.entry_group.delete(0, tk.END)

    def _remove_group(self):
        for i in reversed(list(self.listbox.curselection())):
            del self.targets[i]
        self._refresh_list()

    def _clear_groups(self):
        if self.targets and not messagebox.askyesno("确认", "确定清空所有目标群？"):
            return
        self.targets.clear()
        self._refresh_list()

    def _import_groups(self):
        win = tk.Toplevel(self.root)
        win.title("批量导入目标群")
        win.geometry("420x400")
        ttk.Label(win, text="每行一个群名，空行忽略：").pack(anchor="w", padx=10, pady=(10, 4))
        txt = scrolledtext.ScrolledText(win, wrap="word")
        txt.pack(fill="both", expand=True, padx=10, pady=4)

        def do_import():
            added = 0
            for line in txt.get("1.0", "end").splitlines():
                name = line.strip()
                if name and name != self.source_var.get().strip() and name not in self.targets:
                    self.targets.append(name)
                    added += 1
            self._refresh_list()
            self.log(f"批量导入完成，新增 {added} 个群")
            win.destroy()

        bar = ttk.Frame(win)
        bar.pack(fill="x", padx=10, pady=(0, 10))
        ttk.Button(bar, text="导入", command=do_import).pack(side="right")
        ttk.Button(bar, text="取消", command=win.destroy).pack(side="right", padx=6)

    # ---------------- 日志 / 状态 ----------------
    def log(self, msg, tag=None):
        def _write():
            self.log_text.config(state="normal")
            self.log_text.insert(tk.END, f"[{time.strftime('%H:%M:%S')}] {msg}\n", tag)
            self.log_text.see(tk.END)
            self.log_text.config(state="disabled")
        self.root.after(0, _write)

    def _clear_log(self):
        self.log_text.config(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.config(state="disabled")

    def _set_running(self, running):
        def _do():
            self.btn_start.config(state="disabled" if running else "normal")
            self.btn_stop.config(state="normal" if running else "disabled")
            self.btn_test.config(state="disabled" if running else "normal")
        self.root.after(0, _do)

    def _check_env(self):
        self.log(f"运行环境：Python {sys.version.split()[0]} / Windows")
        if not _is_admin():
            self.log("提示：若微信是“以管理员身份运行”，本工具也需同样提权，否则按键无效", "warn")
        if find_wechat_window() is None:
            self.log("未检测到微信窗口，请先登录并打开微信电脑版", "warn")
        else:
            self.log("已检测到微信窗口", "ok")

    # ---------------- 配置 ----------------
    def _load_config(self):
        if not os.path.exists(CONFIG_PATH):
            return
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg = json.load(f)
            self.source_var.set(cfg.get("source", ""))
            self.own_name_var.set(cfg.get("own_name", ""))
            self.targets = list(cfg.get("targets", []))
            self.poll_var.set(float(cfg.get("poll", 3.0)))
            self.interval_var.set(float(cfg.get("interval", 5.0)))
            self.send_key_var.set(cfg.get("send_key", "Enter"))
            self.left_var.set(float(cfg.get("left_px", 320)))
            self.top_var.set(float(cfg.get("top_px", 100)))
            self.bottom_var.set(float(cfg.get("bottom_px", 155)))
            self._refresh_list()
            self.log(f"已载入配置：源群「{self.source_var.get()}」，{len(self.targets)} 个目标群")
        except Exception as e:
            self.log(f"读取配置失败：{e}", "warn")

    def _save_config(self):
        try:
            cfg = {
                "source": self.source_var.get().strip(),
                "own_name": self.own_name_var.get().strip(),
                "targets": self.targets,
                "poll": self.poll_var.get(),
                "interval": self.interval_var.get(),
                "send_key": self.send_key_var.get(),
                "left_px": self.left_var.get(),
                "top_px": self.top_var.get(),
                "bottom_px": self.bottom_var.get(),
            }
            temp_path = CONFIG_PATH + ".tmp"
            with open(temp_path, "w", encoding="utf-8") as f:
                json.dump(cfg, f, ensure_ascii=False, indent=2)
            os.replace(temp_path, CONFIG_PATH)
        except Exception as e:
            self.log(f"保存配置失败：{e}", "warn")

    # ---------------- OCR ----------------
    def _get_engine(self):
        if self._engine is None:
            from rapidocr_onnxruntime import RapidOCR
            self.log("正在加载 OCR 引擎（首次约需几秒）…")
            self._engine = RapidOCR()
            self.log("OCR 引擎就绪", "ok")
        return self._engine

    def _test_ocr(self):
        if self._thread and self._thread.is_alive():
            return
        try:
            left, top, bottom = self._region()
        except (ValueError, tk.TclError) as e:
            messagebox.showwarning("参数无效", str(e))
            return

        def work():
            try:
                win = find_wechat_window()
                if win is None:
                    self.log("未找到微信窗口", "err")
                    return
                engine = self._get_engine()
                activate_window(win)
                time.sleep(0.6)
                title = read_chat_title(win, engine)
                if not group_title_matches(title, source):
                    self.log(f"当前群标题为「{title or '未读取到'}」，请打开已填写的源群。", "err")
                    return
                img = grab_region(win, left, top, bottom)
                self.log(f"当前会话标题识别为：{read_chat_title(win, engine) or '（读取失败）'}")
                msgs = parse_messages(engine, img)
                self.log(f"识别到 {len(msgs)} 条消息：")
                for sender, content in msgs[-10:]:
                    self.log(f"  [{sender or '未知'}] {content}")
                if not msgs:
                    self.log("没有识别到消息，请检查识别区域比例是否覆盖聊天区", "warn")
            except Exception as e:
                self.log(f"测试失败：{e}", "err")

        source = self.source_var.get().strip()
        self._start_worker(work)

    def _start_worker(self, action, args=()):
        self._stop.clear()
        self._set_running(True)

        def run():
            try:
                with auto.UIAutomationInitializerInThread():
                    action(*args)
            except Exception as e:
                self.log(f"运行失败：{e}", "err")
            finally:
                self._set_running(False)

        self._thread = threading.Thread(target=run, daemon=True)
        self._thread.start()

    def _region(self):
        values = self.left_var.get(), self.top_var.get(), self.bottom_var.get()
        if not all(math.isfinite(value) for value in values) or not (
            100 <= values[0] <= 700 and 0 <= values[1] <= 400 and 50 <= values[2] <= 400
        ):
            raise ValueError("请输入选项标示范围内的截图边距。")
        return values

    # ---------------- 监听主流程 ----------------
    def _start(self):
        if self._thread and self._thread.is_alive():
            return
        source = self.source_var.get().strip()
        if not source:
            messagebox.showwarning("提示", "请先填写源群名称。")
            return
        targets = unique_targets(source, self.targets)
        if not targets:
            messagebox.showwarning("提示", "请至少添加一个目标群（不能与源群相同）。")
            return
        try:
            poll, interval = self.poll_var.get(), self.interval_var.get()
            if not (2 <= poll <= 60 and 2 <= interval <= 120):
                raise ValueError("识别间隔应为 2 至 60 秒，发送间隔应为 2 至 120 秒。")
            left, top, bottom = self._region()
        except (ValueError, tk.TclError) as e:
            messagebox.showwarning("参数无效", str(e))
            return
        dry_run = self.dry_run_var.get()
        if not dry_run and not messagebox.askyesno(
            "确认", f"把「{source}」的新增文字自动转发到以下群？\n\n" + "\n".join(targets) + "\n\n"
                    "开始后请勿操作微信窗口。是否继续？"
        ):
            return

        self._save_config()
        self._start_worker(self._loop, (
            source, targets, poll, interval, dry_run, self.send_key_var.get(),
            left, top, bottom, self.own_name_var.get().strip(),
        ))

    def _stop_relay(self):
        self._stop.set()
        self.log("已请求停止，本轮结束后退出…", "warn")

    def _loop(self, source, targets, poll, interval, dry_run, send_key,
              left_px, top_px, bottom_px, own_name=""):
        tracker, forwarded = SnapshotTracker(), 0
        pending = []
        try:
            win = find_wechat_window()
            if win is None:
                self.log("未找到微信窗口，请先登录微信电脑版", "err")
                return
            engine = self._get_engine()
            activate_window(win)
            self.log(f"开始监听「{source}」→ {len(targets)} 个目标群"
                     f"{'（演练模式，不发送）' if dry_run else ''}")

            while not self._stop.is_set():
                ensure_chat(win, source, engine)
                try:
                    img = grab_region(win, left_px, top_px, bottom_px)
                    msgs = parse_messages(engine, img)
                except DesktopUnavailable:
                    raise
                except Exception as e:
                    self.log(f"识别失败（重试中）：{e}", "warn")
                    self._sleep(poll)
                    continue

                state, new_msgs = tracker.update(msgs)
                if state == "baseline":
                    self.log(f"已建立基线，当前画面的 {len(msgs)} 条消息作为历史。")
                elif state == "gap":
                    self.log("当前与上一帧没有重叠，已重建基线。若刚才有消息滚出屏幕，请在源群核对。", "warn")

                for sender, content in new_msgs:
                    if relay_echo(sender, content):
                        continue
                    shown_sender = (own_name or "我") if sender == "我" else sender
                    text = format_message(source, shown_sender, content)
                    if dry_run:
                        self.log(f"[演练] → {', '.join(targets)}\n{text}", "warn")
                    else:
                        if len(pending) >= 200:
                            raise RuntimeError("待转发队列已满，已停止监听，请检查失败日志")
                        pending.append(PendingDelivery(text, targets))

                attempted = bool(pending)
                for item in list(pending):
                    for target in list(item.remaining):
                        if self._stop.is_set():
                            break
                        try:
                            ensure_chat(win, target, engine)
                            if self._stop.is_set():
                                break
                            sent = send_text(win, item.text, send_key, expected_group=target,
                                             engine=engine, stopped=self._stop.is_set)
                            if not sent:
                                break
                        except DesktopUnavailable:
                            raise
                        except DeliveryUncertain as e:
                            item.remaining.remove(target)
                            item.failed.append(target)
                            self.log(f"目标「{target}」发送状态未知，不自动重试：{e}；消息：{item.text}", "err")
                        except Exception as e:
                            item.failure(target)
                            self.log(f"目标「{target}」第 {item.attempts[target]} 次失败：{e}；"
                                     f"消息：{item.text}", "err")
                            if target in item.failed:
                                self.log(f"目标「{target}」连续三次失败，需人工处理该消息", "err")
                        else:
                            item.success(target)
                            self.log(f"已提交发送到「{target}」：{item.text[-60:]}")
                            self._sleep(interval)
                    if not item.remaining:
                        pending.remove(item)
                        if not item.failed:
                            forwarded += 1
                            self.log(f"累计向全部目标提交 {forwarded} 条（未核验送达）", "ok")
                    if self._stop.is_set():
                        break

                if attempted and not self._stop.is_set():
                    ensure_chat(win, source, engine)
                self._sleep(poll)

        except Exception as e:
            self.log(f"运行出错：{e}", "err")
        finally:
            if pending:
                self.log(f"停止时仍有 {len(pending)} 条待处理消息；待发队列未持久化，请核对日志后人工处理", "warn")
                for item in pending:
                    self.log(f"未提交目标：{item.remaining}；消息：{item.text}", "warn")
            self.log("监听已停止")

    def _sleep(self, seconds):
        self._stop.wait(max(0.0, seconds))

    def on_close(self):
        self._save_config()
        self._stop.set()
        self.root.destroy()


def main():
    global auto
    if not sys.platform.startswith("win"):
        _fatal("不支持的系统", "本工具依赖 Windows UI 自动化，只能在 Windows 10/11 上运行。")
    try:
        ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
        import uiautomation as auto
        from mss import MSS
        from rapidocr_onnxruntime import RapidOCR
    except (ImportError, OSError) as e:
        _fatal("依赖加载失败", f"请使用 start-windows.bat 启动。\n{e}")

    root = tk.Tk()
    try:
        style = ttk.Style()
        if "vista" in style.theme_names():
            style.theme_use("vista")
    except Exception:
        pass
    app = RelayApp(root)
    root.protocol("WM_DELETE_WINDOW", app.on_close)
    root.mainloop()


if __name__ == "__main__":
    main()
