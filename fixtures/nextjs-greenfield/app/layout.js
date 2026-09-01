export const metadata = {
  title: "web-frontend",
  description: "greenfield e2e fixture",
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
