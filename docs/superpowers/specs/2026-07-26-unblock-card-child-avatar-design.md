# Unblock Card Child Avatar Design

## Goal

Show each child's current profile photo in the `Blocked apps` restriction
picker. Preserve the existing initial-based avatar as the final fallback.

## Scope

This change applies only to child-group avatars in
`AppControlCardKind.restrictionUnlockPicker`. It does not add API calls,
change profile storage, or alter other confirmation cards. `AsyncImage` still
performs its normal image download for each URL it attempts.

## Data Flow

`ChatView` already has access to `FamilyStore`. It will project the store's
current child profiles into a child-ID-to-avatar-URL map and pass that map to
`AppControlCard`.

For each restriction group, `AppControlCard` will build an ordered list of
valid, distinct image URLs:

1. The matching child's current `FamilyStore` avatar URL.
2. The avatar URL included in the backend restriction-picker payload.
If the first URL fails to load, the card attempts the next URL. The existing
colored initial is shown only after every candidate URL is absent, invalid, or
fails to load.

The backend group `child_id` remains the identity key. Device IDs and child
names are not used for matching.

## Failure Handling

An absent or syntactically invalid URL falls through to the next source. An
`AsyncImage` loading failure advances to the next candidate URL before using
the initial fallback. The card does not block, refresh family data, or issue
another API call while waiting for an image.

## Testing

Add a pure avatar-resolution helper so unit tests can verify:

- A FamilyStore URL overrides the backend payload URL for the same child.
- The backend URL is used when FamilyStore has no photo.
- An invalid FamilyStore URL falls through to the backend URL.
- A child ID absent from FamilyStore falls through to the backend URL.
- A failed FamilyStore image load advances to the backend URL.
- No URL produces the existing fallback path.

Compile and run the focused app-control card tests to verify the SwiftUI caller
uses the resolved URL without changing restriction actions or labels.
