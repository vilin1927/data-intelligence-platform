'use client';

import { useState, useRef, useEffect, useCallback } from 'react';
import { HelpCircle } from 'lucide-react';

interface InfoTooltipProps {
  text: string;
  size?: number;
  className?: string;
}

export default function InfoTooltip({ text, size = 12, className = '' }: InfoTooltipProps) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const popoverRef = useRef<HTMLDivElement>(null);
  const [position, setPosition] = useState<{ top?: number; left?: number }>({});
  const [arrowSide, setArrowSide] = useState<'bottom' | 'top'>('bottom');

  const calculatePosition = useCallback(() => {
    if (!ref.current || !popoverRef.current) return;
    const btn = ref.current.getBoundingClientRect();
    const pop = popoverRef.current.getBoundingClientRect();
    const vw = window.innerWidth;
    const vh = window.innerHeight;

    // Vertical: prefer above, fall back to below
    let top: number;
    if (btn.top < pop.height + 12) {
      // Not enough space above, show below
      top = btn.bottom + 8;
      setArrowSide('top');
    } else {
      // Show above
      top = btn.top - pop.height - 8;
      setArrowSide('bottom');
    }

    // Horizontal: center on button, clamp to viewport
    let left = btn.left + btn.width / 2 - pop.width / 2;
    if (left < 8) left = 8;
    if (left + pop.width > vw - 8) left = vw - pop.width - 8;

    // Clamp vertical to viewport
    if (top < 8) top = 8;
    if (top + pop.height > vh - 8) top = vh - pop.height - 8;

    setPosition({ top, left });
  }, []);

  useEffect(() => {
    if (!open) return;
    // Calculate on next frame so popover is rendered
    requestAnimationFrame(calculatePosition);

    function handleClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, [open, calculatePosition]);

  return (
    <div ref={ref} className={`inline-flex ${className}`}>
      <button
        type="button"
        onClick={(e) => { e.stopPropagation(); setOpen(!open); }}
        className="text-[#B0B1B3] hover:text-[#505052] transition-colors focus:outline-none"
        aria-label="More info"
      >
        <HelpCircle size={size} />
      </button>
      {open && (
        <div
          ref={popoverRef}
          className="fixed z-[9999] w-64 px-3 py-2 rounded-lg bg-[#1F1F1F] text-white text-xs leading-relaxed shadow-lg"
          style={{
            fontFamily: 'Inter, sans-serif',
            top: position.top ?? 0,
            left: position.left ?? 0,
          }}
        >
          {text}
          {arrowSide === 'bottom' && (
            <div className="absolute top-full left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-l-transparent border-r-[6px] border-r-transparent border-t-[6px] border-t-[#1F1F1F]" />
          )}
          {arrowSide === 'top' && (
            <div className="absolute bottom-full left-1/2 -translate-x-1/2 w-0 h-0 border-l-[6px] border-l-transparent border-r-[6px] border-r-transparent border-b-[6px] border-b-[#1F1F1F]" />
          )}
        </div>
      )}
    </div>
  );
}

interface InfoBannerProps {
  title: string;
  text: string;
  variant?: 'info' | 'tip';
}

export function InfoBanner({ title, text, variant = 'info' }: InfoBannerProps) {
  const [dismissed, setDismissed] = useState(false);
  if (dismissed) return null;

  const colors = variant === 'tip'
    ? 'bg-[#1B7A3D]/5 border-[#1B7A3D]/20 text-[#1B7A3D]'
    : 'bg-[#931220]/5 border-[#931220]/20 text-[#931220]';

  return (
    <div className={`rounded-xl border px-4 py-3 flex items-start justify-between ${colors}`}>
      <div>
        <p className="text-xs font-semibold" style={{ fontFamily: 'Inter, sans-serif' }}>{title}</p>
        <p className="text-xs mt-0.5 opacity-80" style={{ fontFamily: 'Inter, sans-serif' }}>{text}</p>
      </div>
      <button
        onClick={() => setDismissed(true)}
        className="opacity-50 hover:opacity-100 text-lg leading-none ml-3 -mt-0.5"
      >
        &times;
      </button>
    </div>
  );
}
