import { faker } from 'https://cdnjs.cloudflare.com/ajax/libs/Faker.js/5.5.3/faker.min.js';

export const options = { iterations: 1, vus: 1 };

export default function() {
  console.log('lorem: ' + faker.lorem.sentence());
}
