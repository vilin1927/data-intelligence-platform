import { TrendingUp, TrendingDown } from 'lucide-react';

interface MetricCardProps {
  label: string;
  value: string | number;
  trend?: {
    value: number;
    isPositive: boolean;
  };
  subtitle?: string;
  icon?: React.ReactNode;
}

export default function MetricCard({
  label,
  value,
  trend,
  subtitle,
  icon,
}: MetricCardProps) {
  return (
    <div className="bg-white rounded-xl border border-[#D8D9DA] p-6 shadow-sm h-full">
      <div className="flex items-start justify-between">
        <div>
          <p
            className="text-[#505052] text-sm font-medium"
            style={{ fontFamily: 'Inter, sans-serif' }}
          >
            {label}
          </p>
          <p
            className="text-[#1F1F1F] text-2xl font-semibold mt-1"
            style={{ fontFamily: 'Cardo, serif' }}
          >
            {value}
          </p>
          {trend && (
            <div className="flex items-center gap-1 mt-2">
              {trend.isPositive ? (
                <TrendingUp size={14} className="text-[#1B7A3D]" />
              ) : (
                <TrendingDown size={14} className="text-[#B42318]" />
              )}
              <span
                className={`text-xs font-medium ${
                  trend.isPositive ? 'text-[#1B7A3D]' : 'text-[#B42318]'
                }`}
                style={{ fontFamily: 'Inter, sans-serif' }}
              >
                {trend.isPositive ? '+' : ''}{trend.value}%
              </span>
            </div>
          )}
          {subtitle && (
            <p
              className="text-[#505052]/70 text-xs mt-2"
              style={{ fontFamily: 'Inter, sans-serif' }}
            >
              {subtitle}
            </p>
          )}
        </div>
        {icon && (
          <div className="w-10 h-10 rounded-lg bg-[#931220]/10 flex items-center justify-center text-[#931220]">
            {icon}
          </div>
        )}
      </div>
    </div>
  );
}
