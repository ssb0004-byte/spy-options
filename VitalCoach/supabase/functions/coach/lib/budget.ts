// Server-side cost controls. Pure decision function so it can be unit-tested.

export interface UsageSnapshot {
  userTokensToday: number;
  userRequestsToday: number;
  userRequestsLastMinute: number;
  globalTokensThisMonth: number;
}

export interface Limits {
  daily_token_limit_per_user: number;
  daily_request_limit_per_user: number;
  monthly_token_limit_global: number;
  per_minute_request_limit?: number;
}

export type BudgetDecision =
  | { allowed: true }
  | { allowed: false; code: "rate_limited" | "daily_limit" | "service_budget"; message: string };

export function checkBudget(u: UsageSnapshot, l: Limits, expectedTokens: number): BudgetDecision {
  const perMinute = l.per_minute_request_limit ?? 6;
  if (u.userRequestsLastMinute >= perMinute) {
    return { allowed: false, code: "rate_limited", message: "You're sending messages quickly — please wait a moment and try again." };
  }
  if (u.userRequestsToday >= l.daily_request_limit_per_user || u.userTokensToday + expectedTokens > l.daily_token_limit_per_user) {
    return { allowed: false, code: "daily_limit", message: "You've reached today's coaching limit. It resets tomorrow." };
  }
  if (u.globalTokensThisMonth + expectedTokens > l.monthly_token_limit_global) {
    return { allowed: false, code: "service_budget", message: "The coach is temporarily paused to stay within this month's budget." };
  }
  return { allowed: true };
}

/** Rough pre-flight estimate: ~4 characters per token plus the output allowance. */
export function estimateTokens(promptChars: number, maxOutputTokens: number): number {
  return Math.ceil(promptChars / 4) + maxOutputTokens;
}

export function monthStart(day: string): string {
  return `${day.slice(0, 7)}-01`;
}

/** Monday of the ISO week containing `day` (YYYY-MM-DD). */
export function weekStart(day: string): string {
  const d = new Date(day + "T00:00:00Z");
  const dow = (d.getUTCDay() + 6) % 7; // 0 = Monday
  d.setUTCDate(d.getUTCDate() - dow);
  return d.toISOString().slice(0, 10);
}
