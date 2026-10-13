// Minimal OpenAI Responses API client (POST /v1/responses) using fetch — no SDK dependency.
// store:false asks OpenAI not to retain the response for later retrieval.
import { OUTPUT_SCHEMA } from "./prompt.ts";

export interface ModelConfig {
  prompt_version: string;
  chat_model: string;
  reasoning_effort: string | null;
  max_output_tokens: number;
  daily_token_limit_per_user: number;
  daily_request_limit_per_user: number;
  monthly_token_limit_global: number;
}

export interface ChatTurn { role: "user" | "assistant"; content: string }

export function buildRequest(cfg: ModelConfig, instructions: string, data: string, history: ChatTurn[], userMessage: string | null) {
  const input: { role: string; content: string }[] = [
    { role: "developer", content: data },
    ...history.map((t) => ({ role: t.role, content: t.content })),
  ];
  if (userMessage) input.push({ role: "user", content: userMessage });
  else input.push({ role: "user", content: "Please produce the requested output now." });
  const body: Record<string, unknown> = {
    model: cfg.chat_model,
    instructions,
    input,
    max_output_tokens: cfg.max_output_tokens,
    store: false,
    text: { format: { type: "json_schema", name: "coach_reply", schema: OUTPUT_SCHEMA, strict: true } },
  };
  if (cfg.reasoning_effort) body.reasoning = { effort: cfg.reasoning_effort };
  return body;
}

export interface ModelResult { text: string | null; inputTokens: number; outputTokens: number; status: string }

export function extractResult(json: any): ModelResult {
  let text: string | null = null;
  for (const item of Array.isArray(json?.output) ? json.output : []) {
    if (item?.type !== "message") continue;
    for (const c of Array.isArray(item.content) ? item.content : []) {
      if (c?.type === "output_text" && typeof c.text === "string") text = (text ?? "") + c.text;
      if (c?.type === "refusal") text = null;
    }
  }
  return {
    text,
    inputTokens: Number(json?.usage?.input_tokens ?? 0),
    outputTokens: Number(json?.usage?.output_tokens ?? 0),
    status: String(json?.status ?? "unknown"),
  };
}

export class ProviderError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string) {
    super(`provider ${status} ${code}`);
    this.status = status;
    this.code = code;
  }
}

export async function callModel(apiKey: string, body: Record<string, unknown>, fetcher: typeof fetch = fetch, timeoutMs = 60_000): Promise<ModelResult> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetcher("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok) throw new ProviderError(res.status, String(json?.error?.code ?? json?.error?.type ?? "error"));
    return extractResult(json);
  } catch (e) {
    if (e instanceof ProviderError) throw e;
    throw new ProviderError(0, (e as Error)?.name === "AbortError" ? "timeout" : "network");
  } finally {
    clearTimeout(timer);
  }
}
