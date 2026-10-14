'use client';

import { useState } from 'react';
import { useChat } from '@ai-sdk/react';
import AppLayout from '@/components/AppLayout';
import ChatInterface from '@/components/ChatInterface';

export default function ChatPage() {
  const [input, setInput] = useState('');
  const { messages, sendMessage, status, error } = useChat();

  const isLoading = status === 'streaming' || status === 'submitted';

  const handleSend = (text: string) => {
    if (!text.trim() || isLoading) return;
    sendMessage({ text });
    setInput('');
  };

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    handleSend(input);
  };

  return (
    <AppLayout>
      <div className="-m-8 flex flex-col" style={{ height: 'calc(100vh - 0px)' }}>
        <ChatInterface
          messages={messages}
          input={input}
          onInputChange={setInput}
          onSubmit={handleSubmit}
          isLoading={isLoading}
          onSampleClick={handleSend}
          error={error}
        />
      </div>
    </AppLayout>
  );
}
