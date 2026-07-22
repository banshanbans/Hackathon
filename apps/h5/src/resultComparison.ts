import type { Capture } from "./apiClient";

export type ResultComparisonItem =
  | { kind: "reference"; label: "参考"; accessibilityLabel: "参考图"; capture: null }
  | {
      kind: "first" | "second";
      label: "第一拍" | "第二拍";
      accessibilityLabel: "第一拍照片" | "第二拍照片";
      capture: Capture;
    };

export function buildResultComparisonItems(captures: Capture[]): ResultComparisonItem[] {
  const first = captures.find((capture) => capture.round_index === 1);
  const second = captures.find((capture) => capture.round_index === 2);
  const items: ResultComparisonItem[] = [
    { kind: "reference", label: "参考", accessibilityLabel: "参考图", capture: null },
  ];
  if (first !== undefined) {
    items.push({
      kind: "first",
      label: "第一拍",
      accessibilityLabel: "第一拍照片",
      capture: first,
    });
  }
  if (second !== undefined) {
    items.push({
      kind: "second",
      label: "第二拍",
      accessibilityLabel: "第二拍照片",
      capture: second,
    });
  }
  return items;
}
