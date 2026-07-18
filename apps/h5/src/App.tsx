import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState } from "react";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { BrandHeader } from "./components/AppChrome";
import { FlowProvider } from "./flow/FlowProvider";
import { HandoffLandingScreen, HandoffScreen } from "./screens/HandoffScreens";
import {
  AnalysisScreen,
  CaptureScreen,
  EvaluationScreen,
  NotFoundScreen,
  PlanScreen,
  ResultScreen,
  SceneScreen,
} from "./screens/SessionScreens";
import { ConstraintsScreen, EntryScreen, ReferenceScreen } from "./screens/StartScreens";

export function App() {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: {
          queries: { retry: 1, staleTime: 5_000 },
          mutations: { retry: 0 },
        },
      }),
  );
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <FlowProvider>
          <div className="app-shell">
            <BrandHeader />
            <main>
              <Routes>
                <Route path="/" element={<EntryScreen />} />
                <Route path="/reference" element={<ReferenceScreen />} />
                <Route path="/constraints" element={<ConstraintsScreen />} />
                <Route path="/session/:id/analysis" element={<AnalysisScreen />} />
                <Route path="/session/:id/scene" element={<SceneScreen />} />
                <Route path="/session/:id/plan" element={<PlanScreen />} />
                <Route path="/session/:id/handoff" element={<HandoffScreen />} />
                <Route path="/session/:id/capture/:round" element={<CaptureScreen />} />
                <Route path="/session/:id/evaluation/:round" element={<EvaluationScreen />} />
                <Route path="/session/:id/result" element={<ResultScreen />} />
                <Route path="/handoff/:code" element={<HandoffLandingScreen />} />
                <Route path="*" element={<NotFoundScreen />} />
              </Routes>
            </main>
          </div>
        </FlowProvider>
      </BrowserRouter>
    </QueryClientProvider>
  );
}
