import Link from 'next/link';

export default function NotFound() {
  return (
    <div className="min-h-screen bg-[#FAF9F7] flex items-center justify-center">
      <div className="text-center max-w-md px-6">
        <div className="w-16 h-16 rounded-2xl bg-[#931220]/10 flex items-center justify-center mx-auto mb-6">
          <span className="text-3xl font-bold text-[#931220]" style={{ fontFamily: 'Cardo, serif' }}>404</span>
        </div>
        <h1 className="text-xl font-semibold text-[#1F1F1F] mb-2" style={{ fontFamily: 'Cardo, serif' }}>
          Page not found
        </h1>
        <p className="text-sm text-[#505052] mb-6" style={{ fontFamily: 'Inter, sans-serif' }}>
          The page you're looking for doesn't exist or has been moved.
        </p>
        <Link
          href="/"
          className="inline-flex items-center gap-2 px-4 py-2 bg-[#0E0F0F] text-white text-sm rounded-lg hover:bg-[#1F1F1F] transition-colors"
          style={{ fontFamily: 'Inter, sans-serif' }}
        >
          Back to Dashboard
        </Link>
      </div>
    </div>
  );
}
