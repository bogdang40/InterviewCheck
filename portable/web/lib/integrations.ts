export type ProviderStatus = {
  transcription?: boolean;
  reference?: boolean;
  embedding?: boolean;
  judge?: boolean;
  access: boolean;
  inviteRequired?: boolean;
  signedIn?: boolean;
  ats?: string[];
  calendars?: string[];
  meetings?: string[];
};

export async function integration<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers);
  headers.set("X-InterviewCheck", "1");
  const response = await fetch("/api/integrations/" + path, { ...options, headers, cache: "no-store" });
  const data = await response.json();
  if (!response.ok) {
    throw new Error(typeof data.detail === "string" ? data.detail : "The request failed. Check the supplied values.");
  }
  return data as T;
}

export function submit<T>(path: string, data?: unknown) {
  return integration<T>(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: data === undefined ? undefined : JSON.stringify(data),
  });
}
