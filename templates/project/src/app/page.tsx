// Server Component (no directive needed). src/app/ is framework wiring only:
// pages READ by calling a feature service function; no business logic here.
const projectName = "{{PROJECT_NAME}}";

export default function HomePage() {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center gap-2">
      <h1 className="text-2xl font-semibold text-primary">{projectName}</h1>
      <p className="text-sm">
        Bootstrapped by forja. Replace this page with your first feature.
      </p>
    </main>
  );
}
