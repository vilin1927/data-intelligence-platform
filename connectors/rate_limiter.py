"""
Centralised API rate limiter for Moppity Vineyards ETL platform.

Implements ADR-007: token-bucket algorithm shared across all connectors
(Vinsight, Xero, Google Sheets) via a thread-safe singleton.

Limits enforced:
    - Per-minute: 60 tokens, refilling at 1 token/second.
    - Per-day: configurable cap (default 4500, leaving headroom from 5000).

Usage:
    from connectors.rate_limiter import RateLimiter

    limiter = RateLimiter.get_instance()
    limiter.wait_for_token()   # blocks until a token is available
    response = requests.get(...)
"""

import logging
import threading
import time
from datetime import date

logger = logging.getLogger("moppity.rate_limiter")


class RateLimiter:
    """Thread-safe token-bucket rate limiter with daily call counter.

    The singleton instance is retrieved via ``RateLimiter.get_instance()``.
    All connectors share the same instance so that combined API traffic
    stays within the limits of the most restrictive source system
    (Vinsight: 60/min, 5000/day).

    Attributes:
        capacity: Maximum number of tokens in the bucket.
        refill_rate: Tokens added per second.
        daily_limit: Maximum API calls allowed per calendar day.
    """

    _instance: "RateLimiter | None" = None
    _instance_lock = threading.Lock()

    # ------------------------------------------------------------------ #
    # Singleton accessor
    # ------------------------------------------------------------------ #

    @classmethod
    def get_instance(
        cls,
        capacity: int = 60,
        refill_rate: float = 1.0,
        daily_limit: int = 4500,
    ) -> "RateLimiter":
        """Return the singleton RateLimiter, creating it on first call.

        Args:
            capacity: Token bucket size (default 60 — one minute of calls).
            refill_rate: Tokens restored per second (default 1.0).
            daily_limit: Hard cap on daily API calls (default 4500).

        Returns:
            The shared RateLimiter instance.
        """
        if cls._instance is None:
            with cls._instance_lock:
                # Double-checked locking
                if cls._instance is None:
                    cls._instance = cls(
                        capacity=capacity,
                        refill_rate=refill_rate,
                        daily_limit=daily_limit,
                    )
        return cls._instance

    @classmethod
    def _reset_instance(cls) -> None:
        """Reset the singleton (for testing only)."""
        with cls._instance_lock:
            cls._instance = None

    # ------------------------------------------------------------------ #
    # Construction
    # ------------------------------------------------------------------ #

    def __init__(
        self,
        capacity: int = 60,
        refill_rate: float = 1.0,
        daily_limit: int = 4500,
    ) -> None:
        self.capacity = capacity
        self.refill_rate = refill_rate
        self.daily_limit = daily_limit

        self._tokens: float = float(capacity)
        self._last_refill: float = time.monotonic()

        self._daily_count: int = 0
        self._daily_date: date = date.today()

        self._lock = threading.Lock()

    # ------------------------------------------------------------------ #
    # Public API
    # ------------------------------------------------------------------ #

    def wait_for_token(self) -> None:
        """Block the calling thread until a token is available.

        Raises:
            RuntimeError: If the daily call limit has been reached.
                Callers should catch this and abort the current sync run
                gracefully rather than retrying.
        """
        while True:
            with self._lock:
                self._refill()
                self._roll_daily_counter()

                # Daily limit check
                if self._daily_count >= self.daily_limit:
                    logger.error(
                        "Daily API call limit reached (%d/%d). "
                        "No more calls allowed until tomorrow.",
                        self._daily_count,
                        self.daily_limit,
                    )
                    raise RuntimeError(
                        f"Daily API call limit reached "
                        f"({self._daily_count}/{self.daily_limit}). "
                        f"Retry after midnight."
                    )

                # Token available — consume it
                if self._tokens >= 1.0:
                    self._tokens -= 1.0
                    self._daily_count += 1
                    return

                # No token available — compute how long to wait
                wait_seconds = (1.0 - self._tokens) / self.refill_rate

            # Release the lock while sleeping so other threads aren't blocked
            logger.debug(
                "Rate limited — waiting %.2fs for next token "
                "(bucket=%.1f, daily=%d/%d)",
                wait_seconds, self._tokens,
                self._daily_count, self.daily_limit,
            )
            time.sleep(wait_seconds)

    @property
    def daily_calls_remaining(self) -> int:
        """Return the number of API calls remaining today."""
        with self._lock:
            self._roll_daily_counter()
            return max(0, self.daily_limit - self._daily_count)

    @property
    def tokens_available(self) -> float:
        """Return the current number of tokens in the bucket."""
        with self._lock:
            self._refill()
            return self._tokens

    def reset_daily_counter(self) -> None:
        """Manually reset the daily call counter to zero.

        Useful for testing or when the operator explicitly wants to
        allow more calls (e.g. after raising the daily limit upstream).
        """
        with self._lock:
            previous = self._daily_count
            self._daily_count = 0
            self._daily_date = date.today()
        logger.info(
            "Daily counter manually reset (was %d, now 0).", previous
        )

    # ------------------------------------------------------------------ #
    # Internal helpers (must be called with self._lock held)
    # ------------------------------------------------------------------ #

    def _refill(self) -> None:
        """Add tokens based on elapsed time since last refill."""
        now = time.monotonic()
        elapsed = now - self._last_refill
        new_tokens = elapsed * self.refill_rate
        self._tokens = min(self.capacity, self._tokens + new_tokens)
        self._last_refill = now

    def _roll_daily_counter(self) -> None:
        """Reset the daily counter if the calendar date has changed."""
        today = date.today()
        if today != self._daily_date:
            logger.info(
                "New day detected (%s → %s). Resetting daily counter "
                "(was %d).",
                self._daily_date.isoformat(),
                today.isoformat(),
                self._daily_count,
            )
            self._daily_count = 0
            self._daily_date = today
