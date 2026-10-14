'use client';

import { useRef, useEffect } from 'react';
import { type UIMessage } from 'ai';
import ChatMessage from './ChatMessage';
import PresetReportButtons from './PresetReportButtons';
import { Send, Loader2, MessageSquare } from 'lucide-react';

interface ChatInterfaceProps {
  messages: UIMessage[];
  input: string;
  onInputChange: (value: string) => void;
  onSubmit: (e: React.FormEvent) => void;
  isLoading: boolean;
  onSampleClick: (prompt: string) => void;
  error?: Error;
}

export default function ChatInterface({
  messages,
  input,
  onInputChange,
  onSubmit,
  isLoading,
  onSampleClick,
  error,
}: ChatInterfaceProps) {
  const messagesEndRef = useRef<HTMLDivElement>(null);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Auto-scroll to bottom on new messages
  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [messages]);

  // Auto-resize textarea
  useEffect(() => {
    const textarea = textareaRef.current;
    if (textarea) {
      textarea.style.height = 'auto';
      textarea.style.height = Math.min(textarea.scrollHeight, 120) + 'px';
    }
  }, [input]);

  const handleKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      if (input.trim() && !isLoading) {
        onSubmit(e as unknown as React.FormEvent);
      }
    }
  };

  const isEmpty = messages.length === 0;

  return (
    <div className="flex flex-col h-full">
      {/* Messages area */}
      <div className="flex-1 overflow-y-auto px-4 py-6">
        {isEmpty ? (
          <div className="flex flex-col items-center justify-center h-full max-w-2xl mx-auto">
            <div className="w-14 h-14 rounded-2xl bg-[#931220]/10 flex items-center justify-center mb-6">
              <MessageSquare size={28} className="text-[#931220]" />
            </div>
            <h2
              className="text-xl font-semibold text-[#1F1F1F] mb-2"
              style={{ fontFamily: 'Cardo, serif' }}
            >
              Reports
            </h2>
            <p
              className="text-[#505052] text-sm mb-8 text-center"
              style={{ fontFamily: 'Inter, sans-serif' }}
            >
              Pick a 1-click report below — or type any free-form question. Reports run against the period set by the
              global month selector above.
            </p>

            {/* JC-330/331/335 — preset 1-click report buttons replace prompt chips */}
            <PresetReportButtons onPick={onSampleClick} />
          </div>
        ) : (
          <div className="max-w-3xl mx-auto">
            {messages.map((message) => (
              <ChatMessage
                key={message.id}
                role={message.role as 'user' | 'assistant'}
                parts={message.parts}
              />
            ))}

            {/* Loading indicator */}
            {isLoading && (
              <div className="flex justify-start mb-4">
                <div className="bg-white border border-[#E5E5E5] rounded-2xl rounded-bl-md px-4 py-3 shadow-sm">
                  <div className="flex items-center gap-2 text-sm text-[#505052]">
                    <Loader2 size={14} className="animate-spin" />
                    <span>Analysing your data...</span>
                  </div>
                </div>
              </div>
            )}

            <div ref={messagesEndRef} />
          </div>
        )}
      </div>

      {/* Error banner (BUG-A7-FOLLOWUP 2026-05-20: surface Anthropic credit-low + rate-limit explicitly) */}
      {error && (
        <div className="border-t border-red-200 bg-red-50 px-4 py-3">
          <div className="max-w-3xl mx-auto text-sm text-red-800" style={{ fontFamily: 'Inter, sans-serif' }}>
            {error.message || 'Chat request failed. Try again shortly.'}
          </div>
        </div>
      )}

      {/* Input area */}
      <div className="border-t border-[#E5E5E5] bg-white px-4 py-3">
        <form onSubmit={onSubmit} className="max-w-3xl mx-auto flex items-end gap-2">
          <div className="flex-1 relative">
            <textarea
              ref={textareaRef}
              value={input}
              onChange={(e) => onInputChange(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Ask a question about your business..."
              rows={1}
              className="w-full resize-none rounded-xl border border-[#D8D9DA] bg-[#FAF9F7] px-4 py-3 text-sm text-[#1F1F1F] placeholder-[#A0A0A0] focus:outline-none focus:border-[#931220] focus:ring-1 focus:ring-[#931220]/20 transition-colors"
              style={{ fontFamily: 'Inter, sans-serif', maxHeight: '120px' }}
              disabled={isLoading}
            />
          </div>
          <button
            type="submit"
            disabled={!input.trim() || isLoading}
            className="flex-shrink-0 w-10 h-10 rounded-xl bg-[#931220] text-white flex items-center justify-center hover:bg-[#7a0f1b] disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            {isLoading ? (
              <Loader2 size={16} className="animate-spin" />
            ) : (
              <Send size={16} />
            )}
          </button>
        </form>
        <p className="text-center text-xs text-[#A0A0A0] mt-2 max-w-3xl mx-auto" style={{ fontFamily: 'Inter, sans-serif' }}>
          AI responses are based on your database. Always verify critical business decisions.
        </p>
      </div>
    </div>
  );
}
