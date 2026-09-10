// Runs only on GitHub's runner. Signing credentials never leave its environment.
import { createPrivateKey, sign } from 'node:crypto';
const b64 = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const now = Math.floor(Date.now()/1000);
const unsigned = `${b64({ alg: 'ES256', kid: process.env.ASC_KEY_ID, typ: 'JWT' })}.${b64({ iss: process.env.ASC_ISSUER_ID, iat: now, exp: now+600, aud: 'appstoreconnect-v1' })}`;
const token = `${unsigned}.${sign('sha256', Buffer.from(unsigned), { key: createPrivateKey(process.env.ASC_KEY_P8), dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
async function api(path, method='GET', body) {
  const url = new URL(path, 'https://api.appstoreconnect.apple.com');
  if (url.origin !== 'https://api.appstoreconnect.apple.com') throw new Error('Unexpected API origin');
  const r = await fetch(url, { method, redirect: 'error', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  const data = r.status === 204 ? {} : await r.json();
  if (!r.ok) throw new Error(`Apple ${r.status}: ${data.errors?.map(e=>`${e.code}: ${e.detail}`).join('; ')?.slice(0,1000) || 'Request failed'}`);
  return data;
}
const rel = (type,id) => ({ data: { type,id } });
try {
  const apps = await api('/v1/apps?filter[bundleId]=com.photodash.app');
  const app = apps.data?.[0]; if (!app) throw new Error('PhotoDash App Store record not found');
  console.log(`PhotoDash Apple app ID: ${app.id}`);
  const products = await api(`/v1/apps/${app.id}/inAppPurchasesV2?limit=200`);
  let product = products.data.find(p=>p.attributes.productId === 'com.photodash.app.credits10');
  if (!product) product = (await api('/v2/inAppPurchases','POST',{ data: { type:'inAppPurchases', attributes: { name:'PhotoDash 10 Photo Credits', productId:'com.photodash.app.credits10', inAppPurchaseType:'CONSUMABLE', reviewNote:'One credit pays for one bracket set to be professionally processed into one real-estate photo. Credits never expire. Sign in with PhotoDash, then select Buy credits on the submission screen.' }, relationships:{ app:rel('apps',app.id) } } })).data;
  console.log(`Credit product: ${product.id}, ${product.attributes.productId}, ${product.attributes.state}`);
  const localizations = await api(`/v2/inAppPurchases/${product.id}/inAppPurchaseLocalizations`);
  if (!localizations.data.some(l=>l.attributes.locale === 'en-US')) await api('/v1/inAppPurchaseLocalizations','POST',{ data: { type:'inAppPurchaseLocalizations', attributes: { locale:'en-US', name:'10 Photo Credits', description:'Process 10 real-estate photos. Credits never expire.' }, relationships:{ inAppPurchaseV2:rel('inAppPurchases',product.id) } } });
  let page = await api(`/v2/inAppPurchases/${product.id}/pricePoints?filter[territory]=USA&limit=200`); const prices = [...page.data];
  while(page.links?.next) { page = await api(page.links.next); prices.push(...page.data); }
  const price = prices.find(p=>Number(p.attributes.customerPrice) === 10);
  if (!price) throw new Error('Apple has no exact $10 USD price point. Choose a supported price before enabling purchases.');
  await api('/v1/inAppPurchasePriceSchedules','POST',{ data:{ type:'inAppPurchasePriceSchedules', relationships:{ inAppPurchase:rel('inAppPurchases',product.id), baseTerritory:rel('territories','USA'), manualPrices:{ data:[{type:'inAppPurchasePrices',id:'${price}'}] } } }, included:[{type:'inAppPurchasePrices', id:'${price}', attributes:{ startDate:null }, relationships:{ inAppPurchaseV2:rel('inAppPurchases',product.id), inAppPurchasePricePoint:rel('inAppPurchasePricePoints',price.id) } }] });
  console.log('US base price configured: $10.00 for 10 credits.');
  const territories = await api('/v1/territories?limit=200');
  try { await api('/v1/inAppPurchaseAvailabilities','POST',{data:{type:'inAppPurchaseAvailabilities',attributes:{availableInNewTerritories:true},relationships:{inAppPurchase:rel('inAppPurchases',product.id),availableTerritories:{data:territories.data.map(t=>({type:'territories',id:t.id}))}}}}); }
  catch (e) { if (!e.message.includes('409')) throw e; console.log('Availability already exists; existing territories preserved.'); }
  const endpoint = 'https://orangered-armadillo-437592.hostingersite.com/api/v1/credits/apple';
  await api(`/v1/apps/${app.id}`,'PATCH',{ data:{ type:'apps',id:app.id,attributes:{ subscriptionStatusUrl:endpoint,subscriptionStatusUrlVersion:'V2',subscriptionStatusUrlForSandbox:endpoint,subscriptionStatusUrlVersionForSandbox:'V2' } } });
  console.log('Apple credit catalog and signed notification URLs configured. Paid Apps agreement, tax and banking must be active in App Store Connect before purchases work.');
} catch (error) { console.error(error.message?.startsWith('Apple ') ? error.message : String(error.message).slice(0,300)); process.exitCode=1; }
