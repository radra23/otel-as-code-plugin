import { request } from 'undici'

export default defineEventHandler(async () => {
  const { statusCode } = await request('https://inventory.internal/reserve', { method: 'POST' })
  return { reserved: statusCode === 200 }
})
