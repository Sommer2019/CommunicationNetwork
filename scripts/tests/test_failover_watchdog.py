"""
Tests für den Failover Watchdog
================================
Überprüft die Kernlogik des Watchdogs (tcp_ping, failover/failback-Trigger)
mit Hilfe von Mocks – kein laufender Redis- oder Minecraft-Server erforderlich.
"""

import time
import unittest
from unittest.mock import MagicMock, patch
import socket
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from failover_watchdog import tcp_ping, trigger_failover, trigger_failback
import failover_watchdog as wdog


class TestTcpPing(unittest.TestCase):
    """Tests für die tcp_ping()-Funktion."""

    def test_ping_success(self):
        """tcp_ping gibt True zurück, wenn die Verbindung erfolgreich ist."""
        with patch("socket.create_connection") as mock_conn:
            mock_conn.return_value.__enter__ = MagicMock(return_value=None)
            mock_conn.return_value.__exit__ = MagicMock(return_value=False)
            result = tcp_ping("127.0.0.1", 25565)
        self.assertTrue(result)

    def test_ping_connection_refused(self):
        """tcp_ping gibt False zurück, wenn die Verbindung verweigert wird."""
        with patch("socket.create_connection", side_effect=ConnectionRefusedError):
            result = tcp_ping("127.0.0.1", 25565)
        self.assertFalse(result)

    def test_ping_timeout(self):
        """tcp_ping gibt False zurück, wenn ein Timeout auftritt."""
        with patch("socket.create_connection", side_effect=socket.timeout):
            result = tcp_ping("127.0.0.1", 25565)
        self.assertFalse(result)

    def test_ping_os_error(self):
        """tcp_ping gibt False zurück, bei allgemeinen Netzwerkfehlern."""
        with patch("socket.create_connection", side_effect=OSError("Network unreachable")):
            result = tcp_ping("192.168.99.99", 25565)
        self.assertFalse(result)


class TestFailoverTrigger(unittest.TestCase):
    """Tests für trigger_failover() und trigger_failback()."""

    def setUp(self):
        self.redis_mock = MagicMock()

    def test_trigger_failover_sets_active_server_to_b(self):
        """trigger_failover() setzt den aktiven Server auf 'server-b'."""
        trigger_failover(self.redis_mock)

        set_calls = {c.args[0]: c.args[1] for c in self.redis_mock.set.call_args_list}
        self.assertEqual(set_calls.get(wdog.REDIS_KEY_ACTIVE_SERVER), "server-b")

    def test_trigger_failover_sets_status_to_failover(self):
        """trigger_failover() setzt den Status auf 'failover'."""
        trigger_failover(self.redis_mock)

        set_calls = {c.args[0]: c.args[1] for c in self.redis_mock.set.call_args_list}
        self.assertEqual(set_calls.get(wdog.REDIS_KEY_STATUS), "failover")

    def test_trigger_failover_records_timestamp(self):
        """trigger_failover() speichert einen Unix-Timestamp."""
        before = int(time.time())
        trigger_failover(self.redis_mock)
        after = int(time.time())

        set_calls = {c.args[0]: c.args[1] for c in self.redis_mock.set.call_args_list}
        ts = set_calls.get(wdog.REDIS_KEY_LAST_FAILOVER)
        self.assertIsNotNone(ts)
        self.assertGreaterEqual(ts, before)
        self.assertLessEqual(ts, after)

    def test_trigger_failback_sets_active_server_to_a(self):
        """trigger_failback() setzt den aktiven Server auf 'server-a'."""
        trigger_failback(self.redis_mock)

        set_calls = {c.args[0]: c.args[1] for c in self.redis_mock.set.call_args_list}
        self.assertEqual(set_calls.get(wdog.REDIS_KEY_ACTIVE_SERVER), "server-a")

    def test_trigger_failback_sets_status_to_normal(self):
        """trigger_failback() setzt den Status auf 'normal'."""
        trigger_failback(self.redis_mock)

        set_calls = {c.args[0]: c.args[1] for c in self.redis_mock.set.call_args_list}
        self.assertEqual(set_calls.get(wdog.REDIS_KEY_STATUS), "normal")

    def test_trigger_failback_deletes_failure_count(self):
        """trigger_failback() löscht den Fehlerzähler aus Redis."""
        trigger_failback(self.redis_mock)
        self.redis_mock.delete.assert_called_once_with(wdog.REDIS_KEY_FAILURE_COUNT)


class TestMainLoopLogic(unittest.TestCase):
    """
    Integrationstests für die Haupt-Schleife des Watchdogs.
    Simuliert verschiedene Szenarien mit einer begrenzten Anzahl von Iterationen.
    """

    def _run_main(self, ping_responses, failure_threshold=3, max_iterations=10):
        """Führt main() mit gemockten Abhängigkeiten aus."""
        redis_mock = MagicMock()
        redis_mock.ping.return_value = True
        failover_calls = []
        failback_calls = []

        def mock_trigger_failover(r):
            failover_calls.append(True)

        def mock_trigger_failback(r):
            failback_calls.append(True)

        iterations = [0]

        def limited_sleep(_):
            iterations[0] += 1
            if iterations[0] >= max_iterations:
                raise StopIteration

        with patch("failover_watchdog.get_redis_client", return_value=redis_mock), \
             patch("failover_watchdog.tcp_ping", side_effect=ping_responses), \
             patch("failover_watchdog.FAILURE_THRESHOLD", failure_threshold), \
             patch("failover_watchdog.CHECK_INTERVAL", 0), \
             patch("failover_watchdog.trigger_failover", side_effect=mock_trigger_failover), \
             patch("failover_watchdog.trigger_failback", side_effect=mock_trigger_failback), \
             patch("time.sleep", side_effect=limited_sleep):
            try:
                wdog.main()
            except StopIteration:
                pass

        return failover_calls, failback_calls

    def test_failover_triggers_after_threshold(self):
        """Nach FAILURE_THRESHOLD Fehlern wird Failover ausgelöst.

        Aufruf-Sequenz von tcp_ping bei threshold=3:
          Iter 1: primary → False  (count=1, kein Standby-Ping da count < threshold)
          Iter 2: primary → False  (count=2, kein Standby-Ping da count < threshold)
          Iter 3: primary → False  (count=3 == threshold) → Standby-Ping → True → FAILOVER
        """
        ping_responses = iter([
            False,        # iter 1: primary down (count=1)
            False,        # iter 2: primary down (count=2)
            False, True,  # iter 3: primary down (count=3), standby up → FAILOVER
        ])
        failover_calls, _ = self._run_main(ping_responses, failure_threshold=3, max_iterations=3)
        self.assertEqual(len(failover_calls), 1)

    def test_no_failover_if_threshold_not_reached(self):
        """Kein Failover, wenn Fehlerzähler unter dem Schwellenwert bleibt.

        Aufruf-Sequenz bei threshold=3:
          Iter 1: primary → False (count=1)
          Iter 2: primary → False (count=2, threshold noch nicht erreicht)
          Iter 3: primary → True  (zähler zurückgesetzt, kein Failover)
        """
        ping_responses = iter([
            False,  # iter 1: primary down (count=1)
            False,  # iter 2: primary down (count=2)
            True,   # iter 3: primary wieder up → kein Failover
        ])
        failover_calls, _ = self._run_main(ping_responses, failure_threshold=3, max_iterations=3)
        self.assertEqual(len(failover_calls), 0)

    def test_no_failover_if_standby_also_down(self):
        """Kein Failover, wenn auch Server-B nicht erreichbar ist.

        Aufruf-Sequenz bei threshold=3:
          Iter 1: primary → False (count=1)
          Iter 2: primary → False (count=2)
          Iter 3: primary → False (count=3==threshold), standby → False → kein Failover
        """
        ping_responses = iter([
            False,         # iter 1: primary down (count=1)
            False,         # iter 2: primary down (count=2)
            False, False,  # iter 3: primary down (count=3), standby auch down → kein Failover
        ])
        failover_calls, _ = self._run_main(ping_responses, failure_threshold=3, max_iterations=3)
        self.assertEqual(len(failover_calls), 0)

    def test_failback_after_recovery(self):
        """Failback wird ausgelöst, wenn Server-A nach einem Failover wieder verfügbar ist.

        Aufruf-Sequenz bei threshold=2:
          Iter 1: primary → False (count=1)
          Iter 2: primary → False (count=2==threshold), standby → True → FAILOVER
          Iter 3: primary → True  (recovered), failover_active=True, standby → True → FAILBACK
        """
        ping_responses = iter([
            False,        # iter 1: primary down (count=1)
            False, True,  # iter 2: primary down (count=2==threshold), standby up → FAILOVER
            True,  True,  # iter 3: primary wieder up, standby up → FAILBACK
        ])
        failover_calls, failback_calls = self._run_main(
            ping_responses, failure_threshold=2, max_iterations=3
        )
        self.assertEqual(len(failover_calls), 1, "Failover sollte einmal ausgelöst worden sein")
        self.assertEqual(len(failback_calls), 1, "Failback sollte nach Recovery ausgelöst worden sein")


if __name__ == "__main__":
    unittest.main()
