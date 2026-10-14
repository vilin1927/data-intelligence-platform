'use client';

import { createContext, useContext, useState, useCallback, ReactNode } from 'react';
import { X, CheckCircle, AlertCircle, AlertTriangle, Info } from 'lucide-react';

type ToastVariant = 'success' | 'error' | 'warning' | 'info';

interface Toast {
  id: string;
  message: string;
  variant: ToastVariant;
}

interface ToastContextType {
  toasts: Toast[];
  addToast: (message: string, variant?: ToastVariant) => void;
  removeToast: (id: string) => void;
}

const ToastContext = createContext<ToastContextType | undefined>(undefined);

const variantStyles: Record<ToastVariant, { bg: string; icon: ReactNode; border: string }> = {
  success: {
    bg: 'bg-[#ECFDF3]',
    border: 'border-[#A6F4C5]',
    icon: <CheckCircle size={18} className="text-[#1B7A3D]" />,
  },
  error: {
    bg: 'bg-[#FEF3F2]',
    border: 'border-[#FECACA]',
    icon: <AlertCircle size={18} className="text-[#B42318]" />,
  },
  warning: {
    bg: 'bg-[#FFFAEB]',
    border: 'border-[#FDE68A]',
    icon: <AlertTriangle size={18} className="text-[#B54708]" />,
  },
  info: {
    bg: 'bg-[#EFF6FF]',
    border: 'border-[#BFDBFE]',
    icon: <Info size={18} className="text-[#1D4ED8]" />,
  },
};

function ToastItem({ toast, onRemove }: { toast: Toast; onRemove: () => void }) {
  const style = variantStyles[toast.variant];

  return (
    <div
      className={`
        flex items-center gap-3 px-4 py-3 rounded-lg border shadow-lg
        animate-slide-in
        ${style.bg} ${style.border}
      `}
      style={{ fontFamily: 'Inter, sans-serif' }}
    >
      {style.icon}
      <p className="text-sm text-[#1F1F1F] flex-1">{toast.message}</p>
      <button
        onClick={onRemove}
        className="text-[#505052] hover:text-[#1F1F1F] transition-colors"
      >
        <X size={16} />
      </button>
    </div>
  );
}

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const addToast = useCallback((message: string, variant: ToastVariant = 'info') => {
    const id = Math.random().toString(36).substring(2, 9);
    setToasts((prev) => [...prev, { id, message, variant }]);

    // Auto-dismiss after 5 seconds
    setTimeout(() => {
      setToasts((prev) => prev.filter((t) => t.id !== id));
    }, 5000);
  }, []);

  const removeToast = useCallback((id: string) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  return (
    <ToastContext.Provider value={{ toasts, addToast, removeToast }}>
      {children}
      {/* Toast container - bottom right */}
      <div className="fixed bottom-4 right-4 z-50 flex flex-col gap-2 max-w-sm">
        {toasts.map((toast) => (
          <ToastItem
            key={toast.id}
            toast={toast}
            onRemove={() => removeToast(toast.id)}
          />
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export function useToast() {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error('useToast must be used within a ToastProvider');
  }
  return context;
}
