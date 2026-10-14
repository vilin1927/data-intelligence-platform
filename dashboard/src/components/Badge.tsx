type BadgeVariant = 'success' | 'warning' | 'error' | 'info' | 'neutral' | 'p2';

interface BadgeProps {
  variant: BadgeVariant;
  children: React.ReactNode;
}

const variantStyles: Record<BadgeVariant, string> = {
  success: 'bg-[#ECFDF3] text-[#1B7A3D] border-[#A6F4C5]',
  warning: 'bg-[#FFFAEB] text-[#B54708] border-[#FDE68A]',
  error: 'bg-[#FEF3F2] text-[#B42318] border-[#FECACA]',
  info: 'bg-[#EFF6FF] text-[#1D4ED8] border-[#BFDBFE]',
  neutral: 'bg-[#F5F4F2] text-[#505052] border-[#D8D9DA]',
  p2: 'bg-[#F5F4F2] text-[#931220] border-[#D8D9DA]',
};

export default function Badge({ variant, children }: BadgeProps) {
  return (
    <span
      className={`
        inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium border
        ${variantStyles[variant]}
      `}
      style={{ fontFamily: 'Inter, sans-serif' }}
    >
      {children}
    </span>
  );
}
