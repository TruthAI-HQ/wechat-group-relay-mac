"""Offline checks using the production flow with a fake WeChat desktop."""
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import wechat_group_relay as relay
from relay_logic import (
    DeliveryUncertain, DesktopUnavailable, SnapshotTracker,
    group_title_matches, relay_echo, unique_targets,
)


def row(text, y):
    return {"text": text, "x0": 20, "x1": 160, "y0": y, "y1": y + 20}


class RulesTest(unittest.TestCase):
    def test_title_needs_exact_name_and_group_count(self):
        self.assertTrue(group_title_matches("测试群 2（10）", "测试群 2"))
        for title in ("测试群 21 (10)", "测试群 2", ""):
            self.assertFalse(group_title_matches(title, "测试群 2"))

    def test_contact_never_used_as_search_result(self):
        rows = [row("联系人", 10), row("测试群", 35), row("群聊", 70), row("测试群", 100)]
        self.assertEqual(relay._find_group_row(rows, "测试群"), (rows[-1], True))

    def test_duplicate_group_names_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "同名群"):
            relay._find_group_row([row("群聊", 10), row("测试群", 35), row("测试群", 65)], "测试群")

    def test_exact_output_and_own_messages(self):
        text = relay.format_message("源群", "林", "第一行\n第二行")
        self.assertEqual(text, "来自 源群 的 林 ：\n--------------------------------\n第一行\n第二行")
        self.assertTrue(relay_echo("助手", text))
        self.assertFalse(relay_echo("我", "正常文字"))

    def test_target_list(self):
        self.assertEqual(unique_targets("源群", ["目标甲 ", "", "源群", "目标乙", "目标甲"]), ["目标甲", "目标乙"])

    def test_baseline_blank_duplicate_and_repeated_text(self):
        tracker = SnapshotTracker()
        self.assertEqual(tracker.update([]), ("empty", ()))
        self.assertEqual(tracker.update(["旧内容"]), ("baseline", ()))
        self.assertEqual(tracker.update([]), ("empty", ()))
        self.assertEqual(tracker.update(["旧内容", "旧内容"]), ("updated", ("旧内容",)))
        self.assertEqual(tracker.update(["旧内容", "旧内容"]), ("unchanged", ()))

    def test_viewport_overlap_and_gap(self):
        tracker = SnapshotTracker()
        tracker.update(["a", "b", "c"])
        self.assertEqual(tracker.update(["b", "c", "d"]), ("updated", ("d",)))
        self.assertEqual(tracker.update(["x", "y"]), ("gap", ()))
        self.assertEqual(tracker.update(["x", "y", "z"]), ("updated", ("z",)))


class OCRTest(unittest.TestCase):
    @staticmethod
    def parse(lines):
        boxes = [([[x,y], [x+140,y], [x+140,y+18], [x,y+18]], text, score)
                 for text, x, y, score in lines]
        return relay.parse_messages(lambda image: (boxes, 0), SimpleNamespace(shape=(720, 750, 3)))

    def test_multiline_text_and_sender(self):
        self.assertEqual(self.parse([("小林", 20, 10, 0.99), ("第一行", 45, 34, 0.99),
                                     ("第二行", 45, 58, 0.99)]), [("小林", "第一行\n第二行")])

    def test_nontext_placeholders_and_photo_sender(self):
        for body in ("[图片]", "[动画表情]", "[语音]", "[文件]", "引用：上一条"):
            self.assertEqual(self.parse([("昵称", 20, 10, 0.99), (body, 45, 34, 0.99)]), [])
        self.assertEqual(self.parse([("只有昵称", 20, 10, 0.99)]), [])

    def test_right_side_kept_and_low_confidence_skipped(self):
        self.assertEqual(self.parse([("自己的消息", 520, 10, 0.99)]), [("我", "自己的消息")])
        self.assertEqual(self.parse([("低置信内容", 45, 10, 0.50)]), [])


class WorkflowTest(unittest.TestCase):
    def run_relay(self, frames, *, dry=False, fail=None, stop_at_target=False):
        app = relay.RelayApp.__new__(relay.RelayApp)
        app._stop = threading.Event()
        app.log = Mock()
        app._get_engine = Mock(return_value=object())
        latest = [0]
        posted = []
        attempts = {}

        def sleep(delay):
            if delay == 3:
                latest[0] += 1
                if latest[0] >= len(frames):
                    app._stop.set()

        def select(win, group, engine):
            if group == "源群":
                return
            if stop_at_target:
                app._stop.set()
            attempts[group] = attempts.get(group, 0) + 1
            if fail == "preflight" and group == "目标乙" and attempts[group] == 1:
                raise RuntimeError("临时不可定位")

        def post(win, text, send_key, **kwargs):
            if fail == "uncertain":
                raise DeliveryUncertain("虚拟发送状态不明")
            posted.append((kwargs["expected_group"], text))
            return True

        app._sleep = sleep
        window = object()
        with patch.multiple(
            relay, find_wechat_window=Mock(return_value=window), activate_window=Mock(),
            ensure_chat=Mock(side_effect=select), grab_region=Mock(),
            parse_messages=Mock(side_effect=lambda *args: frames[latest[0]]), send_text=Mock(side_effect=post),
        ):
            app._loop("源群", ["目标甲", "目标乙"], 3, 5, dry, "Enter", 320, 100, 155, "小林")
        return app, posted, attempts

    def test_new_text_reaches_each_target_once_and_uses_own_nickname(self):
        old = [("小丁", "历史文字")]
        current = old + [("我", "新文字")]
        _, posted, _ = self.run_relay([old, current, current])
        self.assertEqual(posted, [
            ("目标甲", relay.format_message("源群", "小林", "新文字")),
            ("目标乙", relay.format_message("源群", "小林", "新文字")),
        ])

    def test_dry_run_never_opens_targets(self):
        old = [("小丁", "历史文字")]
        app, posted, attempts = self.run_relay([old, old + [("小林", "新文字")]], dry=True)
        self.assertEqual((posted, attempts), ([], {}))
        self.assertIn("[演练]", str(app.log.call_args_list))

    def test_preflight_failure_retries_only_failed_group(self):
        old = [("小丁", "历史文字")]
        current = old + [("小林", "新文字")]
        _, posted, attempts = self.run_relay([old, current, current], fail="preflight")
        self.assertEqual(attempts, {"目标甲": 1, "目标乙": 2})
        self.assertEqual([group for group, _ in posted], ["目标甲", "目标乙"])

    def test_uncertain_send_is_never_retried(self):
        old = [("小丁", "历史文字")]
        current = old + [("小林", "新文字")]
        app, posted, attempts = self.run_relay([old, current, current], fail="uncertain")
        self.assertEqual(posted, [])
        self.assertEqual(attempts, {"目标甲": 1, "目标乙": 1})
        self.assertIn("不自动重试", str(app.log.call_args_list))

    def test_stopping_during_navigation_prevents_send(self):
        old = [("小丁", "历史文字")]
        _, posted, _ = self.run_relay([old, old + [("小林", "新文字")]], stop_at_target=True)
        self.assertEqual(posted, [])

    def test_mismatched_title_blocks_input(self):
        with patch.multiple(relay, read_chat_title=Mock(return_value="错误群 (5)"), _keys=Mock(), auto=Mock()):
            with self.assertRaisesRegex(RuntimeError, "标题核验"):
                relay.send_text(object(), "内容", expected_group="目标甲")
            relay._keys.assert_not_called()
            relay.auto.SetClipboardText.assert_not_called()

    def test_path_cannot_send_after_foreground_changes(self):
        window = SimpleNamespace(NativeWindowHandle=11)
        with patch.object(relay, "_user32", return_value=Mock(GetForegroundWindow=Mock(return_value=22))):
            with self.assertRaises(DesktopUnavailable):
                relay._require_foreground(window)

    def test_stopping_after_paste_prevents_enter(self):
        window = SimpleNamespace(BoundingRectangle=SimpleNamespace(left=0, right=1000, bottom=600))
        stopped = Mock(side_effect=[False, True])
        with patch.multiple(relay, read_chat_title=Mock(return_value="目标甲 (2)"), _grab=Mock(),
                            _ocr_lines=Mock(return_value=[]), focus_input=Mock(), _keys=Mock(), auto=Mock()):
            self.assertFalse(relay.send_text(window, "测试文字", expected_group="目标甲", stopped=stopped))
            relay._keys.assert_called_once_with(window, "{Ctrl}v", 0.35)


if __name__ == "__main__":
    unittest.main(verbosity=2)
