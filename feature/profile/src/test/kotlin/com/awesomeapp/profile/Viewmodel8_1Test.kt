package com.awesomeapp.profile

import org.junit.Test
import org.junit.Before
import org.junit.runner.RunWith
import org.junit.runners.JUnit4
import org.junit.Rule
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import kotlin.test.assertTrue
import kotlin.test.assertNotNull
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import com.awesomeapp.profile.*
import com.awesomeapp.profile.Repository8_5


@OptIn(ExperimentalCoroutinesApi::class)
class Viewmodel8_1Test {
        private lateinit var repository0: Repository8_5

    private lateinit var viewModel: Viewmodel8_1

    @Before
    fun setup() {
       repository0 = Repository8_5(com.awesomeapp.profile.Api8_6())
        viewModel = Viewmodel8_1(
            repository0
        )
    }

    @Test
    fun `test state updates with data`() = runTest {
        assertNotNull(viewModel.state.value)
    }
}
