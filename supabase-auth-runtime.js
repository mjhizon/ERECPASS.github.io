/* Supabase-only authentication for ERecPass. */
(function () {
  'use strict';

  const KEYS = window.DB_KEYS || {
    PATIENTS: 'erecpass_db_patients', STAFF: 'erecpass_db_staff', SESSION: 'erecpass_db_session'
  };
  const client = () => window.erecpassSupabase;
  const cleanEmail = value => String(value || '').trim().toLowerCase();
  let adminLoginInProgress = false;
  const ageFromBirthDate = value => {
    const m = String(value || '').match(/^(\d{4})-(\d{2})-(\d{2})$/);
    if (!m) return null;
    const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]);
    const birth = new Date(y, mo - 1, d), today = new Date();
    if (birth.getFullYear() !== y || birth.getMonth() !== mo - 1 || birth.getDate() !== d || birth > today) return null;
    let age = today.getFullYear() - y;
    if (today.getMonth() < mo - 1 || (today.getMonth() === mo - 1 && today.getDate() < d)) age--;
    return age;
  };

  function showPendingVerification(email) {
    window._erecpassPendingEmail = cleanEmail(email);
    const page = document.getElementById('waitingConfirmPage');
    const label = document.getElementById('waitingConfirmEmail');
    if (label) label.textContent = window._erecpassPendingEmail;
    document.querySelectorAll('.auth-page').forEach(el => el.classList.add('hidden'));
    if (page) { page.classList.remove('hidden'); page.style.display = 'flex'; }
  }

  async function resendSignupEmail(email) {
    const { error } = await client().auth.resend({
      type: 'signup', email: cleanEmail(email)
    });
    if (error) throw error;
  }

  function showAuthError(error, roleLabel) {
    const message = String(error?.message || error || 'Sign in failed.');
    if (/email not confirmed|email_not_confirmed|not confirmed/i.test(message)) {
      const inputId = roleLabel === 'Staff' ? 'staffLoginName' : roleLabel === 'Admin' ? 'adminLoginUser' : 'loginEmail';
      const email = cleanEmail(document.getElementById(inputId)?.value);
      window.erecpassConfirm('Please verify your email first. Resend the Supabase confirmation email?').then(async yes => {
        if (!yes) return;
        try { await resendSignupEmail(email); alert('A new verification email was sent to ' + email + '.'); }
        catch (sendError) { alert('Could not resend the email: ' + (sendError.message || sendError)); }
      });
      return;
    }
    alert((roleLabel ? roleLabel + ' login failed: ' : 'Login failed: ') + message);
  }

  async function completePatientLogin(email, password) {
    const sb = client();
    const auth = await sb.auth.signInWithPassword({ email, password });
    if (auth.error) throw auth.error;
    const user = auth.data?.user;
    if (!user?.id) throw new Error('Supabase did not return a signed-in account.');

    const pendingKey = 'erecpass_pending_patient:' + email;
    let pending = null;
    try { pending = JSON.parse(window.localStorage.getItem(pendingKey) || 'null'); } catch (_) {}
    if (user.user_metadata?.erecpass_pending_registration && !pending) {
      await sb.auth.signOut();
      throw new Error('This registration was started in another browser or its saved details were cleared. Sign in on the browser used to register so your patient details can be saved.');
    }
    let profileResult = await sb.from('profiles').select('id,full_name,role,active').eq('id', user.id).maybeSingle();
    if (profileResult.error) throw profileResult.error;
    let profile = profileResult.data;
    const metadata = user.user_metadata || {};
    const fullName = String(pending?.fullName || profile?.full_name || metadata.full_name || email.split('@')[0]).trim();
    if (!profile) {
      const savedProfile = await sb.from('profiles').upsert({ id: user.id, full_name: fullName, role: 'patient', active: true }, { onConflict: 'id' });
      if (savedProfile.error) throw savedProfile.error;
      profile = { id: user.id, full_name: fullName, role: 'patient', active: true };
    } else if (pending?.fullName && profile.full_name !== pending.fullName) {
      const savedProfile = await sb.from('profiles').update({ full_name: pending.fullName }).eq('id', user.id);
      if (savedProfile.error) throw savedProfile.error;
      profile.full_name = pending.fullName;
    }
    if (String(profile.role || '').toLowerCase() !== 'patient') throw new Error('This account is not enabled for Patient Login.');
    if (profile.active === false) throw new Error('This patient account is deactivated. Login is disabled.');

    let rowResult = await sb.from('patients').select('*').eq('user_id', user.id).maybeSingle();
    if (rowResult.error) throw rowResult.error;
    let row = rowResult.data;
    if (!row) {
      rowResult = await sb.from('patients').select('*').eq('id', user.id).maybeSingle();
      if (rowResult.error) throw rowResult.error;
      row = rowResult.data;
    }
    if (!row) {
      const birthDate = String(pending?.birthDate || metadata.birth_date || '');
      const age = ageFromBirthDate(birthDate);
      const saved = await sb.from('patients').insert({
        id: user.id, user_id: user.id, full_name: fullName, email: user.email || email,
        sim: pending?.sim || metadata.sim || null, birth_date: birthDate || null, age,
        age_category: age === null || age >= 18 ? 'Adult' : 'Minor', status: 'Green', active: true
      }).select('*').single();
      if (saved.error) throw saved.error;
      row = saved.data;
    } else {
      const update = { user_id: user.id };
      if (pending?.fullName || !row.full_name) update.full_name = fullName;
      if (!row.email && user.email) update.email = user.email;
      const sim = pending?.sim || metadata.sim;
      if ((!row.sim || pending?.sim) && sim) update.sim = sim;
      const birthDate = pending?.birthDate || metadata.birth_date;
      if ((!row.birth_date || pending?.birthDate) && birthDate) {
        const age = ageFromBirthDate(birthDate);
        update.birth_date = birthDate;
        update.age = age;
        update.age_category = age === null || age >= 18 ? 'Adult' : 'Minor';
      }
      if (Object.keys(update).length) {
        const saved = await sb.from('patients').update(update).eq('id', row.id).select('*').single();
        if (saved.error) throw saved.error;
        row = saved.data;
      }

    if (pending) {
      const updatedUser = await sb.auth.updateUser({ data: { erecpass_pending_registration: false } });
      if (updatedUser.error) throw updatedUser.error;
      window.localStorage.removeItem(pendingKey);
    }
    }

    const patient = Object.assign({}, row, {
      id: row.id, user_id: user.id, fullName: row.full_name || fullName,
      name: row.full_name || fullName, email: user.email || email,
      birthDate: row.birth_date || '', birth_date: row.birth_date || '', online: true
    });
    window.currentSession = { role: 'patient', data: patient };
    try { currentSession = window.currentSession; } catch (_) {}
    window.epStore?.setItem(KEYS.SESSION, JSON.stringify(window.currentSession));
    if (typeof window.erecpassCloudHydrate === 'function') await window.erecpassCloudHydrate();
    if (typeof window.hideAuthPages === 'function') window.hideAuthPages();
    if (typeof window.launchPortalByRole === 'function') window.launchPortalByRole('patient');
  }

  async function completeRoleLogin(email, password, expectedRole, label) {
    const sb = client();
    if (!sb?.auth || typeof sb.auth.signInWithPassword !== 'function') {
      throw new Error('Supabase authentication is unavailable. Refresh the page and try again.');
    }
    const auth = await sb.auth.signInWithPassword({ email, password });
    if (auth.error) throw auth.error;
    const user = auth.data?.user;
    if (!user?.id) throw new Error('Supabase did not return a signed-in account.');
    if (expectedRole === 'staff') {
      const completion = await sb.functions.invoke('complete-staff-registration');
      if (completion.error) {
        await sb.auth.signOut();
        throw new Error(completion.data?.error || completion.error.message || 'Staff registration could not be completed.');
      }
      if (completion.data?.error) {
        await sb.auth.signOut();
        throw new Error(completion.data.error);
      }
    }
    const result = await sb.from('profiles').select('id,full_name,role,active').eq('id', user.id).maybeSingle();
    if (result.error) {
      if (expectedRole === 'admin') {
        try { await sb.auth.signOut(); }
        catch (signOutError) { console.error('[ERecPass] Could not close unverified Admin session:', signOutError); }
      }
      throw result.error;
    }
    const profile = result.data;
    const roleMatches = profile && String(profile.role || '').toLowerCase() === expectedRole;
    const accountIsActive = expectedRole === 'admin' ? profile?.active === true : profile?.active !== false;
    if (!roleMatches || !accountIsActive) {
      try { await sb.auth.signOut(); }
      catch (signOutError) { console.error('[ERecPass] Could not close rejected ' + label + ' session:', signOutError); }
      if (roleMatches && expectedRole === 'admin') {
        throw new Error('This Admin account is inactive or not enabled. Contact the system administrator.');
      }
      throw new Error(profile?.active === false ? 'This account is deactivated.' : 'This account is not enabled for ' + label + ' Login.');
    }
    if (typeof window.erecpassCloudHydrate === 'function') await window.erecpassCloudHydrate();
    if (window.currentSession?.data?.active === false) {
      await sb.auth.signOut();
      throw new Error('This account is deactivated. Login is disabled.');
    }
    if (typeof window.hideAuthPages === 'function') window.hideAuthPages();
    if (typeof window.launchPortalByRole === 'function') window.launchPortalByRole(expectedRole);
  }

  window.handleRegister = async function (event) {
    event?.preventDefault();
    const first = (document.getElementById('regFirstName')?.value || '').trim();
    const last = (document.getElementById('regLastName')?.value || '').trim();
    const noMiddle = !!document.getElementById('regNoMiddleName')?.checked;
    const middleRaw = (document.getElementById('regMiddleName')?.value || '').trim();
    const middle = (noMiddle || /^n\/?a$/i.test(middleRaw)) ? '' : middleRaw;
    const fullName = [first, middle, last].filter(Boolean).join(' ');
    const email = cleanEmail(document.getElementById('regEmail')?.value);
    const sim = (document.getElementById('regSim')?.value || '').trim();
    const birthDate = (document.getElementById('regBirthDate')?.value || '').trim();
    const password = document.getElementById('regPassword')?.value || '';
    const confirm = document.getElementById('regConfirmPassword')?.value || '';
    const age = ageFromBirthDate(birthDate);
    if (!first || !last) { alert('Please enter your First Name and Last Name.'); return; }
    if (!noMiddle && !middle) { alert('Please enter your Middle Name, or check N/A if you do not have one.'); return; }
    if (!email || !sim || !birthDate || age === null) { alert('Please complete all required fields with a valid date of birth.'); return; }
    if (password !== confirm) { alert('Passwords do not match.'); return; }
    if (password.length < 8 || !/[#!?]/.test(password)) { alert('Password must be at least 8 characters and contain one of these symbols: # ! ?'); return; }
    const pendingKey = 'erecpass_pending_patient:' + email;
    window.localStorage.setItem(pendingKey, JSON.stringify({ fullName, sim, birthDate }));
    const button = document.querySelector('#registerForm button[type="submit"]');
    if (button) { button.disabled = true; button.textContent = 'CREATING ACCOUNT…'; }
    try {
      const { data, error } = await client().auth.signUp({
        email, password,
        options: {
          data: { role: 'patient', erecpass_pending_registration: true }
        }
      });
      if (error) throw error;
      if (!data?.user) throw new Error('Supabase did not create the patient account.');
      if (data.session) {
        await client().auth.signOut();
        document.getElementById('registerForm')?.reset();
        window.showLogin?.();
        alert('Supabase email confirmation is disabled, so this account was created without email verification. Enable Confirm email in Supabase Authentication settings before registering more patients. You can sign in to continue.');
        return;
      }
      document.getElementById('registerForm')?.reset();
      showPendingVerification(email);
      alert('A Supabase confirmation email was sent to ' + email + '. Follow the instructions in the email, then sign in here.');
    } catch (error) {
      console.error('[ERecPass] Patient registration failed:', error);
      const message = String(error?.message || error || 'Registration failed.');
      if (/email rate limit exceeded|over_email_send_rate_limit|email.*rate.?limit/i.test(message)) {
        alert('Supabase has reached its email sending limit. The built-in sender is limited to 2 emails per hour. Set up custom SMTP in Supabase Authentication settings, then try again later. Avoid repeated retries.');
      } else {
        alert('Could not create account: ' + message);
      }
    } finally {
      if (button) { button.disabled = false; button.textContent = 'CREATE ACCOUNT'; }
    }
  };

  window.handleLogin = async function (event) {
    event?.preventDefault();
    const email = cleanEmail(document.getElementById('loginEmail')?.value);
    const password = document.getElementById('loginPassword')?.value || '';
    if (!email || !password) { alert('Please enter your email and password.'); return; }
    try { await completePatientLogin(email, password); }
    catch (error) { console.error('[ERecPass] Patient login failed:', error); showAuthError(error, 'Patient'); }
  };

  window.handleStaffLogin = async function (event) {
    event?.preventDefault();
    const email = cleanEmail(document.getElementById('staffLoginName')?.value);
    const password = document.getElementById('staffLoginPassword')?.value || '';
    if (!email.includes('@') || !password) { alert('Enter your staff email and password.'); return; }
    try { await completeRoleLogin(email, password, 'staff', 'Staff'); }
    catch (error) { console.error('[ERecPass] Staff login failed:', error); showAuthError(error, 'Staff'); }
  };

  window.handleAdminLogin = async function (event) {
    event?.preventDefault();
    if (adminLoginInProgress) return;
    const email = cleanEmail(document.getElementById('adminLoginUser')?.value);
    const password = document.getElementById('adminLoginPassword')?.value || '';
    if (!email || !password) { alert('Please enter your Admin email and password.'); return; }
    const form = document.getElementById('adminLoginForm');
    const button = form?.querySelector('button[type="submit"]');
    const originalLabel = button?.textContent || 'ADMIN LOGIN';
    adminLoginInProgress = true;
    if (button) {
      button.disabled = true;
      button.textContent = 'SIGNING IN...';
    }
    form?.setAttribute('aria-busy', 'true');
    try { await completeRoleLogin(email, password, 'admin', 'Admin'); }
    catch (error) { console.error('[ERecPass] Admin login failed:', error); showAuthError(error, 'Admin'); }
    finally {
      adminLoginInProgress = false;
      if (button) {
        button.disabled = false;
        button.textContent = originalLabel;
      }
      form?.removeAttribute('aria-busy');
    }
  };

  window.showWaitingConfirmation = function (email) {
    showPendingVerification(email || window._erecpassPendingEmail || '');
  };
  window.resendConfirmEmailFromWaiting = async function () {
    const email = cleanEmail(window._erecpassPendingEmail || document.getElementById('regEmail')?.value);
    if (!email) { alert('The registered email address is unavailable. Return to registration and try again.'); return; }
    try { await resendSignupEmail(email); alert('A new Supabase verification email was sent to ' + email + '.'); }
    catch (error) { alert('Could not resend the verification email: ' + (error.message || error)); }
  };

  window.logout = async function () {
    try { await client()?.auth.signOut(); }
    catch (error) { console.warn('[ERecPass] Supabase sign-out warning:', error); }
    window.currentSession = null;
    try { currentSession = null; } catch (_) {}
    window.epStore?.removeItem(KEYS.SESSION);
    ['patientApp', 'staffApp', 'adminApp'].forEach(id => document.getElementById(id)?.classList.add('hidden'));
    if (typeof window.showLogin === 'function') window.showLogin();
  };

  console.info('[ERecPass] Supabase Auth runtime ready.');
})();
