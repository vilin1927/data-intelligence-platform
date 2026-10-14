'use client';

import { useState, FormEvent, Suspense } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';

// Demo mirror flag — hide Moppity brand identity from prospects. Unset => live.
const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const redirectTo = searchParams.get('redirect') || '/';

  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password }),
      });

      if (res.ok) {
        router.push(redirectTo);
        router.refresh();
      } else {
        const data = await res.json();
        setError(data.error || 'Invalid password');
      }
    } catch {
      setError('Connection error. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-[#1a1a1a] relative overflow-hidden">
      {/* Barrels background image */}
      <div
        className="absolute inset-0 bg-cover bg-center"
        style={{ backgroundImage: "url('/images/barrels-bg.jpg')" }}
      />
      {/* Dark overlay for readability */}
      <div className="absolute inset-0 bg-gradient-to-br from-[#0E0F0F]/80 via-[#0E0F0F]/60 to-[#931220]/30" />

      {/* Login card */}
      <div className="relative z-10 w-full max-w-md mx-4">
        <div className="bg-[#FAF9F7] rounded-2xl shadow-2xl p-8">
          {/* Logo and title */}
          <div className="text-center mb-8">
            <h1
              className="text-3xl text-[#0E0F0F] mb-2"
              style={{ fontFamily: 'Cardo, serif' }}
            >
              {VIEW_ONLY ? 'Wine Data Platform' : 'Moppity Vineyards'}
            </h1>
            <p
              className="text-[#505052] text-sm"
              style={{ fontFamily: 'Inter, sans-serif' }}
            >
              Data Intelligence Platform
            </p>
          </div>

          {/* Login form */}
          <form onSubmit={handleSubmit} className="space-y-6">
            <div>
              <label
                htmlFor="password"
                className="block text-sm font-medium text-[#1F1F1F] mb-2"
                style={{ fontFamily: 'Inter, sans-serif' }}
              >
                Password
              </label>
              <input
                id="password"
                type="password"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="Enter your password"
                autoFocus
                disabled={loading}
                className="w-full px-4 py-3 rounded-lg border border-[#D8D9DA] bg-white text-[#1F1F1F] placeholder-[#505052]/60 focus:outline-none focus:ring-2 focus:ring-[#931220]/50 focus:border-[#931220] transition-colors disabled:opacity-60"
                style={{ fontFamily: 'Inter, sans-serif' }}
              />
            </div>

            {/* Error message */}
            {error && (
              <div className="bg-red-50 border border-red-200 text-red-700 px-4 py-3 rounded-lg text-sm" style={{ fontFamily: 'Inter, sans-serif' }}>
                {error}
              </div>
            )}

            {/* Submit button */}
            <button
              type="submit"
              disabled={loading || !password}
              className="w-full py-3 px-4 bg-[#931220] hover:bg-[#7a0f1a] text-white font-medium rounded-lg transition-colors disabled:opacity-60 disabled:cursor-not-allowed flex items-center justify-center gap-2"
              style={{ fontFamily: 'Inter, sans-serif' }}
            >
              {loading ? (
                <>
                  <svg className="animate-spin h-5 w-5" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" fill="none" />
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z" />
                  </svg>
                  Signing in...
                </>
              ) : (
                'Sign In'
              )}
            </button>
          </form>
        </div>

        {/* Footer */}
        <p className="text-center text-[#505052]/60 text-xs mt-6" style={{ fontFamily: 'Inter, sans-serif' }}>
          {VIEW_ONLY ? 'Wine Data Platform' : 'Moppity Wines Pty Ltd'}
        </p>
      </div>
    </div>
  );
}

export default function LoginPage() {
  return (
    <Suspense fallback={
      <div className="min-h-screen flex items-center justify-center bg-[#1a1a1a]">
        <div className="animate-spin h-8 w-8 border-2 border-[#931220] border-t-transparent rounded-full" />
      </div>
    }>
      <LoginForm />
    </Suspense>
  );
}
