export const message = await Promise.resolve('モジュール準備完了');
export async function formatMemo(text) {
  const content = await Promise.resolve(text);
  return content + '・非同期保存';
}
