/**
 * API Client
 *
 * Wraps fetch() for API calls. Authentication is handled via
 * httpOnly session cookies (set at login, sent automatically).
 */

interface FetchOptions extends RequestInit {
  // Additional options can be added here
}

/**
 * Fetch wrapper with credentials
 */
export async function apiFetch(
  url: string,
  options: FetchOptions = {}
): Promise<Response> {
  return fetch(url, {
    ...options,
    credentials: 'same-origin', // Include cookies
  });
}

/**
 * GET request
 */
export async function apiGet(url: string): Promise<Response> {
  return apiFetch(url, { method: 'GET' });
}

/**
 * POST request with JSON body
 */
export async function apiPost(
  url: string,
  body?: unknown
): Promise<Response> {
  const headers: Record<string, string> = {};

  // Add Content-Type for JSON body
  if (body !== undefined && !(body instanceof FormData)) {
    headers['Content-Type'] = 'application/json';
  }

  return apiFetch(url, {
    method: 'POST',
    headers,
    body: body instanceof FormData ? body : JSON.stringify(body),
  });
}

/**
 * POST request with FormData (for file uploads)
 */
export async function apiPostForm(
  url: string,
  formData: FormData
): Promise<Response> {
  return apiFetch(url, {
    method: 'POST',
    body: formData,
  });
}

/**
 * PUT request with JSON body
 */
export async function apiPut(
  url: string,
  body?: unknown
): Promise<Response> {
  const headers: Record<string, string> = {};

  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }

  return apiFetch(url, {
    method: 'PUT',
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
}

/**
 * DELETE request
 */
export async function apiDelete(url: string): Promise<Response> {
  return apiFetch(url, { method: 'DELETE' });
}
