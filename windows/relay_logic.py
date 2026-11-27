"""Pure relay rules. No desktop, network, clipboard or WeChat access."""
import re


class DeliveryUncertain(RuntimeError):
    """A desktop operation failed; sending may already have happened."""


class DesktopUnavailable(RuntimeError):
    """The visible WeChat window can no longer be operated safely."""


def title_matches(title, name):
    """Only accept a complete name; numbered groups must never fuzzy-match."""
    title = re.sub(r"[（(]\s*\d+\s*[)）]\s*$", "", title).strip()
    return bool(title and name.strip() and title == name.strip())


def group_title_matches(title, name):
    return bool(re.search(r"[（(]\s*\d+\s*[)）]\s*$", title)) and title_matches(title, name)


def relay_echo(sender, content):
    return bool(re.match(
        r"^(?:来自 [^\n]+\s*[:：]\r?\n[-—－]{8,}|\[[^\]\n]+@[^\]\n]+\]\s*[:：])", content.strip()))


class SnapshotTracker:
    """Compare the common tail and head of consecutive visible message lists."""

    def __init__(self):
        self.previous = None

    def update(self, messages):
        current = tuple(messages)
        if not current:
            return "empty", ()
        previous, self.previous = self.previous, current
        if previous is None:
            return "baseline", ()
        if previous == current:
            return "unchanged", ()
        for overlap in range(min(len(previous), len(current)), 0, -1):
            if previous[-overlap:] == current[:overlap]:
                return "updated", current[overlap:]
        return "gap", ()


def unique_targets(source, targets):
    return list(dict.fromkeys(t.strip() for t in targets if t.strip() and t.strip() != source.strip()))


class PendingDelivery:
    """Per-target acknowledgements: successful targets are never retried."""
    def __init__(self, text, targets):
        self.text = text
        self.remaining = list(targets)
        self.attempts = dict.fromkeys(targets, 0)
        self.failed = []

    def success(self, target):
        self.remaining.remove(target)

    def failure(self, target):
        self.attempts[target] += 1
        if self.attempts[target] >= 3:
            self.remaining.remove(target)
            self.failed.append(target)
