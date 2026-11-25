// The room's join link as a QR code, drawn as one SVG path in ink on paper: big enough to scan
// from across a table. Medium error correction, a quiet zone of 2 modules.
import { useMemo } from "react";
import { encode } from "uqr";

export function Qr(props: { text: string; label: string }) {
  const { size, path } = useMemo(() => {
    const qr = encode(props.text, { ecc: "M", border: 2 });
    let d = "";
    qr.data.forEach((row, y) =>
      row.forEach((on, x) => {
        if (on) d += `M${x} ${y}h1v1h-1z`;
      }),
    );
    return { size: qr.size, path: d };
  }, [props.text]);
  return (
    <div className="qr">
      <svg viewBox={`0 0 ${size} ${size}`} role="img" aria-label={props.label} shapeRendering="crispEdges">
        <rect width={size} height={size} fill="#fbfcfe" />
        <path d={path} fill="#2340b8" />
      </svg>
    </div>
  );
}
