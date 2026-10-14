import type { Metadata } from 'next';
import { ToastProvider } from '@/components/Toast';
import { GlobalMonthProvider } from '@/lib/globalMonth';
import './globals.css';

const VIEW_ONLY = process.env.NEXT_PUBLIC_VIEW_ONLY === 'true';

export const metadata: Metadata = {
  title: VIEW_ONLY ? 'Wine Data Platform' : 'Moppity Vineyards — Data Platform',
  description: VIEW_ONLY
    ? 'Wine business data intelligence platform'
    : 'Admin dashboard for Moppity Vineyards data intelligence platform',
  icons: {
    icon: '/favicon.png',
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="bg-[#FAF9F7] text-[#1F1F1F] antialiased min-h-screen">
        <ToastProvider>
          <GlobalMonthProvider>
            {children}
          </GlobalMonthProvider>
        </ToastProvider>
      </body>
    </html>
  );
}
