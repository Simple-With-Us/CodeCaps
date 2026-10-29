import test from 'node:test';
import assert from 'node:assert/strict';
import {nextSharedBuild as next} from './shared-build.mjs';
// The merge stamp is set explicitly, so no test depends on the clock or on git.
const STAMP = '202610290930';
const input = {iosBuilds: [], macBuilds: [], complete: true, mergeStamp: STAMP};
test('fresh app plans the merge stamp itself', () => {
  assert.deepEqual(next(input), {build: STAMP});
});
test('existing builds below the stamp plan the stamp', () => {
  assert.deepEqual(next({...input, iosBuilds: ['0.1.3', '1.1.2']}), {build: STAMP});
  assert.deepEqual(next({...input, iosBuilds: ['101']}), {build: STAMP});
  assert.deepEqual(next({...input, macBuilds: ['0.1.3']}), {build: STAMP});
  assert.deepEqual(next({...input, extraFloors: [1500]}), {build: STAMP});
  assert.deepEqual(next({...input, iosBuilds: ['1100'], extraFloors: [1500]}), {build: STAMP});
});
test('an existing build at the stamp plans one above it, so a rebuild goes up', () => {
  assert.deepEqual(next({...input, iosBuilds: [STAMP]}), {build: '202610290931'});
  assert.deepEqual(next({...input, macBuilds: [STAMP]}), {build: '202610290931'});
});
test('an existing build above the stamp plans one above it', () => {
  assert.deepEqual(next({...input, iosBuilds: ['209912312359']}), {build: '209912312360'});
  assert.deepEqual(next({...input, macBuilds: ['209912312359']}), {build: '209912312360'});
  assert.deepEqual(next({...input, extraFloors: [209912312359]}), {build: '209912312360'});
});
test('iOS timestamp builds count like every other build', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645', '202610180127'], mergeStamp: '202610180000'}),
    {build: '202610190646'}
  );
  assert.deepEqual(
    next({...input, iosBuilds: ['202610190645', '2394'], mergeStamp: '202610180000'}),
    {build: '202610190646'}
  );
});
test('a mac-only higher build decides the answer', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['1100'], macBuilds: ['202610290935'], mergeStamp: '202610290900'}),
    {build: '202610290936'}
  );
});
test('dotted builds count by their first numeric component', () => {
  assert.deepEqual(
    next({...input, iosBuilds: ['202610290935.1'], mergeStamp: '202610290900'}),
    {build: '202610290936'}
  );
  assert.deepEqual(next({...input, iosBuilds: ['1.2.3']}), {build: STAMP});
});
test('floors wider than a safe integer ride through as digit strings', () => {
  assert.deepEqual(next({...input, extraFloors: ['202610290940']}), {build: '202610290941'});
});
test('malformed inventory throws before computing', () => {
  for (const bad of [null, 'NaN', '1.2.3.4', 42, '', ' 1000', 'v1']) {
    assert.throws(() => next({...input, iosBuilds: [bad]}), /malformed build inventory/);
    assert.throws(() => next({...input, macBuilds: [bad]}), /malformed build inventory/);
  }
  for (const bad of [-1, 1.5, NaN, '15x0', null, '']) {
    assert.throws(() => next({...input, extraFloors: [bad]}), /malformed build inventory/);
  }
  // A malformed entry is reported even when a higher build would also apply.
  assert.throws(() => next({...input, iosBuilds: ['209912312359', 'NaN']}), /malformed build inventory/);
});
test('a bad merge stamp throws before computing', () => {
  for (const bad of [null, undefined, 202610290930, '', '123', '20261029093', '2026102909301', '022610290930', '20261029093a', ' 202610290930']) {
    assert.throws(() => next({...input, mergeStamp: bad}), /malformed merge stamp/);
  }
  assert.throws(() => next({iosBuilds: [], macBuilds: [], complete: true}), /malformed merge stamp/);
});
test('incomplete inventory refuses', () => {
  assert.throws(() => next({...input, complete: false}), /complete build inventory required/);
  assert.throws(() => next({...input, complete: undefined}), /complete build inventory required/);
  assert.throws(() => next({iosBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
  assert.throws(() => next({macBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
  assert.throws(() => next({iosBuilds: '1000', macBuilds: [], complete: true, mergeStamp: STAMP}), /complete build inventory required/);
});
