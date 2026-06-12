import faker from 'k6/x/faker';

export const options = { iterations: 1, vus: 1 };

export default function() {
  try { console.log('animal: ' + faker.animal.dog()); } catch(e) { console.log('animal err: ' + e); }
  try { console.log('lorem:  ' + faker.lorem.sentence()); } catch(e) { console.log('lorem err: ' + e); }
  try { console.log('date:   ' + faker.date.past()); } catch(e) { console.log('date err: ' + e); }
}
