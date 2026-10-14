export const dynamic = 'force-dynamic';
export const maxDuration = 30;

import { streamText, stepCountIs, convertToModelMessages } from 'ai';
import { anthropic } from '@ai-sdk/anthropic';
import { SYSTEM_PROMPT } from '@/lib/ai-system-prompt';
import { aiTools } from '@/lib/ai-tools';
import { runSqlQuery } from '@/lib/ai-sql-fallback';

/**
 * POST /api/chat
 * Protected by existing auth middleware (session cookie required).
 */
export async function POST(request: Request) {
  try {
    // VIEW_ONLY demo mirror: chat is OFF by default. Flip DEMO_CHAT_ENABLED=true
    // to re-enable (the table allowlist in ai-sql-fallback backstops that).
    // Both flags unset (live editor) => this is a no-op, zero behavior change.
    if (process.env.VIEW_ONLY === 'true' && process.env.DEMO_CHAT_ENABLED !== 'true') {
      return new Response(JSON.stringify({ error: 'AI chat is not available in this demo.' }), {
        status: 503,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const { messages } = await request.json();

    if (!messages || !Array.isArray(messages)) {
      return new Response(JSON.stringify({ error: 'messages array required' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const apiKey = process.env.ANTHROPIC_API_KEY;
    if (!apiKey) {
      console.error('[/api/chat] ANTHROPIC_API_KEY not set');
      return new Response(JSON.stringify({ error: 'AI service not configured' }), {
        status: 500,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    // BUG-13 defensive: tolerate pre-AI-SDK-v6 message shape ({role, content: string})
    // from non-browser integrations (curl/Postman/scanners). The real browser client via
    // useChat() already posts v6 UIMessages with a `parts` array — this normalization is
    // a no-op for valid requests and keeps the endpoint from crashing on legacy shapes.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const normalizedMessages = (messages as any[]).map((m) => {
      if (m && !m.parts && typeof m.content === 'string') {
        return {
          id: m.id || crypto.randomUUID(),
          role: m.role,
          parts: [{ type: 'text', text: m.content }],
        };
      }
      return m;
    });

    const modelMessages = await convertToModelMessages(normalizedMessages);

    const result = streamText({
      model: anthropic('claude-sonnet-4-6'),
      system: SYSTEM_PROMPT,
      messages: modelMessages,
      tools: {
        ...aiTools,
        run_sql_query: runSqlQuery,
      },
      stopWhen: stepCountIs(5),
      onError: ({ error }) => {
        console.error('[/api/chat] stream error:', error);
      },
    });

    return result.toUIMessageStreamResponse({
      onError: (error) => {
        const msg = (error as Error)?.message ?? String(error);
        if (/credit balance.*too low|insufficient.*credit|insufficient_quota/i.test(msg)) {
          return 'Anthropic API credit too low. Top up at https://console.anthropic.com to restore chat.';
        }
        if (/rate[ _-]?limit|\b429\b/i.test(msg)) {
          return 'AI rate limit hit. Wait a moment and try again.';
        }
        if (/timeout|timed out/i.test(msg)) {
          return 'Chat request timed out. Try a shorter question or retry.';
        }
        return 'Chat request failed. Check server logs or retry shortly.';
      },
    });
  } catch (err) {
    console.error('[/api/chat] Error:', err);
    const msg = (err as Error)?.message ?? String(err);
    if (/credit balance.*too low|insufficient.*credit|insufficient_quota/i.test(msg)) {
      return new Response(JSON.stringify({ error: 'Anthropic API credit too low. Top up at https://console.anthropic.com to restore chat.' }), {
        status: 402,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    return new Response(JSON.stringify({ error: 'Chat request failed' }), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    });
  }
}
